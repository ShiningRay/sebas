require "log"
require "json"
require "http/client"
require "crystal_llm"
require "../log"

# Provider 层（M0-WP5 骨架）：规格表（编译期常量，A2）+ 实例池（A1：单实例→实例池）。
# design.md §4.1——每 agent 可绑不同模型/厂商；M1-WP8 的 provider key 热换以实例池为宿主。
module Sebas
  module Providers
    Log = Sebas::Log.for("sebas.providers")

    record Message, role : String, content : String do
      include JSON::Serializable
    end

    # 补全结果（typed rescue 转值纪律：LLM 错误转 Response 不炸进程）
    record Completion, text : String, error : String? do
      def self.error(message : String) : Completion
        new("", message)
      end

      def ok? : Bool
        error.nil?
      end
    end

    # 厂商规格表（A2：编译期常量；新增厂商在此登记）
    record Spec, id : String, base_url : String, format : String

    SPEC_TABLE = {
      "deepseek"   => Spec.new("deepseek", "https://api.deepseek.com", "openai"),
      "openai"     => Spec.new("openai", "https://api.openai.com/v1", "openai"),
      "openrouter" => Spec.new("openrouter", "https://openrouter.ai/api/v1", "openai"),
      "anthropic"  => Spec.new("anthropic", "https://api.anthropic.com/v1", "anthropic"),
    } of String => Spec

    def self.spec_for(provider_ref : String) : Spec?
      SPEC_TABLE[provider_ref]?
    end

    # provider 级配置快照（#214）：GatewaySecrets 从 Config::ProviderConfig 映射；
    # 独立 record 让 Providers 层不依赖 Config 类型（依赖方向：gateway → providers）
    record ProviderCfg, api_key : String?, base_url : String?, protocol : String?

    # 显式 protocol → wire 格式（#214：协议与厂商解耦）
    PROTOCOL_FORMATS = {
      "openai-compatible" => "openai",
      "anthropic"         => "anthropic",
    }

    # 装配决议（#214）：provider 名 / 模型名 / base_url / wire 格式 / 密钥的
    # 单一判定点（纯函数，同样输入必得同样输出）。
    #
    # - provider 名：`provider` > `provider_ref`（兼容）> model 前缀推断（遗留）
    # - 模型名：剥掉与 provider 名相同的冗余前缀（`deepseek/deepseek-chat` →
    #   `deepseek-chat`）；显式 provider 下裸名直传，openrouter 等自带斜杠的
    #   模型 ID（`openai/gpt-4o`）因前缀不等于 provider 名而不受影响
    # - base_url：provider 配置 > 规格表；两者皆缺 = fail-closed
    # - wire 格式：protocol 映射（PROTOCOL_FORMATS）；无 provider 配置时用规格表
    # - 密钥：provider 级 > agent 级（遗留过渡）；均缺返回 nil，装配侧 fail-closed
    record Resolution, name : String, model : String, base_url : String, format : String, api_key : String?

    class ProviderResolveError < ::Exception; end

    def self.resolve(provider : String?, provider_ref : String?, model : String,
                     cfg : ProviderCfg?, spec : Spec?,
                     provider_key : String?, agent_key : String?) : Resolution
      name = provider_name(provider, provider_ref, model)
      model_name = model_name_for(name, model)
      key = provider_key || agent_key
      cfg ? resolve_configured(name, model_name, cfg, spec, key) : resolve_legacy(name, model_name, spec, key)
    end

    private def self.provider_name(provider : String?, provider_ref : String?, model : String) : String
      name = provider || provider_ref || model.split("/").first?
      if name.nil? || name.strip.empty?
        raise ProviderResolveError.new(
          "model '#{model}' does not encode a provider (legacy '<provider>/<model>' form) and agents.<name>.provider is unset")
      end
      name.strip
    end

    private def self.model_name_for(name : String, model : String) : String
      model_name = model.starts_with?("#{name}/") ? model.split("/", limit: 2)[1]? : model
      if model_name.nil? || model_name.strip.empty?
        raise ProviderResolveError.new("model '#{model}' has no model name after provider prefix '#{name}/'")
      end
      model_name
    end

    private def self.resolve_configured(name : String, model_name : String,
                                        cfg : ProviderCfg, spec : Spec?, key : String?) : Resolution
      base = cfg.base_url
      base = spec.try(&.base_url) if base.nil? || base.strip.empty?
      if base.nil? || base.strip.empty?
        raise ProviderResolveError.new("provider '#{name}': base_url missing (set providers.#{name}.base_url)")
      end
      format = PROTOCOL_FORMATS[cfg.protocol]?
      unless format
        raise ProviderResolveError.new(
          "provider '#{name}': unknown protocol '#{cfg.protocol}' (openai-compatible | anthropic)")
      end
      Resolution.new(name, model_name, base, format, key)
    end

    private def self.resolve_legacy(name : String, model_name : String, spec : Spec?, key : String?) : Resolution
      unless spec
        raise ProviderResolveError.new(
          "unknown provider '#{name}' for model '#{model_name}': define a providers.#{name} block with base_url (legacy spec table miss)")
      end
      Resolution.new(name, model_name, spec.base_url, spec.format, key)
    end

    abstract class Provider
      abstract def complete(messages : Array(Message)) : Completion

      getter model : String

      def initialize(@model : String)
      end
    end

    # OpenAI 兼容 chat completions（A2 HttpProvider 骨架：超时/错误兜底；重试与 429 退避 M1 补）
    class HttpProvider < Provider
      def initialize(spec : Spec, @model : String, @api_key : String,
                     @timeout : Time::Span = 60.seconds, @client_base : String? = nil)
        super(@model)
        @spec = spec
      end

      def complete(messages : Array(Message)) : Completion
        case @spec.format
        when "openai"
          complete_openai(messages)
        when "anthropic"
          complete_anthropic(messages)
        else
          Completion.error("provider format '#{@spec.format}' not implemented yet (M1)")
        end
      end

      private def complete_openai(messages : Array(Message)) : Completion
        base = @client_base || @spec.base_url
        uri = URI.parse(base)
        path = uri.path.rstrip('/') + "/chat/completions"
        body = {model: @model, messages: messages.map { |message| {role: message.role, content: message.content} }}.to_json
        headers = HTTP::Headers{
          "Authorization" => "Bearer #{@api_key}",
          "Content-Type"  => "application/json",
        }
        host = uri.host
        return Completion.error("provider base_url missing host") if host.nil? # fail-closed
        client = HTTP::Client.new(host, uri.port || 443, uri.scheme == "https" || uri.port == 443)
        client.connect_timeout = @timeout
        client.read_timeout = @timeout
        response = client.post(path, headers: headers, body: body)
        return Completion.error("provider HTTP #{response.status_code}") unless response.success?
        parsed = JSON.parse(response.body)
        text = parsed.dig?("choices", 0, "message", "content").try(&.as_s) || ""
        Completion.new(text, nil)
      rescue ex : ::Exception
        Completion.error("provider request failed: #{ex.message}")
      end

      # Anthropic Messages API（#214：显式 protocol 路径；非流式、纯文本）。
      # system 消息提升为顶层 system 参数；其余角色映射 user/assistant；
      # 连续同角色合并、首条非 user 时补占位 turn（Anthropic 校验硬约束：
      # 首条必须 user、角色严格交替）。
      private def complete_anthropic(messages : Array(Message)) : Completion
        uri = URI.parse(@spec.base_url)
        host = uri.host
        return Completion.error("provider base_url missing host") if host.nil? # fail-closed
        system_text, turns = normalize_anthropic_messages(messages)
        turns.unshift({role: "user", content: "(continue)"}) if turns.empty? || turns.first[:role] == "assistant"
        body = {model: @model, max_tokens: 4096, messages: turns}
        body = body.merge({system: system_text}) unless system_text.empty?
        headers = HTTP::Headers{
          "x-api-key"         => @api_key,
          "anthropic-version" => "2023-06-01",
          "Content-Type"      => "application/json",
        }
        path = uri.path.rstrip('/') + "/messages"
        client = HTTP::Client.new(host, uri.port || 443, uri.scheme == "https" || uri.port == 443)
        client.connect_timeout = @timeout
        client.read_timeout = @timeout
        response = client.post(path, headers: headers, body: body.to_json)
        return Completion.error("provider HTTP #{response.status_code}") unless response.success?
        parsed = JSON.parse(response.body)
        blocks = parsed.dig?("content").try(&.as_a) || [] of JSON::Any
        text = blocks.select { |block| block.dig?("type").try(&.as_s) == "text" }
          .map { |block| block.dig?("text").try(&.as_s) || "" }.join
        Completion.new(text, nil)
      rescue ex : ::Exception
        Completion.error("provider request failed: #{ex.message}")
      end

      # system 消息提升 + 角色归一（user/assistant）+ 连续同角色合并
      private def normalize_anthropic_messages(messages : Array(Message)) : Tuple(String, Array(NamedTuple(role: String, content: String)))
        system_text = messages.select { |msg| msg.role == "system" }.map(&.content).join("\n\n")
        merged = [] of NamedTuple(role: String, content: String)
        messages.reject { |msg| msg.role == "system" }.each do |msg|
          role = msg.role == "assistant" ? "assistant" : "user"
          prev = merged.last?
          if prev && prev[:role] == role
            merged[-1] = {role: role, content: "#{prev[:content]}\n\n#{msg.content}"}
          else
            merged << {role: role, content: msg.content}
          end
        end
        {system_text, merged}
      end
    end
  end
end
