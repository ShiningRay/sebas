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
    end
  end
end
