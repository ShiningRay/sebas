require "yaml"
require "../../log"
require "../../providers/providers" # validate_providers 查规格表（缺省 base_url 回退合法性）
require "./schema"
require "../../sessions/scheduling/policy"

# 配置加载链（M0-WP2）：读盘 → expand_env → YAML → validate! 失败即拒启
# （复用 autobot loader.cr:152-166 现链思想，design.md §11.2②；校验器为独立纯函数便于 M1-WP8 热更新先验后换复用）
module Sebas
  module Platform
    module Config
      alias Scheduling = ::Sebas::Sessions::Scheduling

      class ConfigError < ::Exception; end

      # 校验失败：聚合全部可读错误行（先验后换时逐行回报）
      class ValidationError < ConfigError
        getter errors : Array(String)

        def initialize(@errors)
          super("config validation failed:\n" + @errors.map { |e| "  - #{e}" }.join("\n"))
        end
      end

      module Loader
        extend self
        Log = ::Sebas::Log.for("config.loader")

        def load(path : String | Path) : Config
          path = Path[path]
          raise ConfigError.new("config file not found: #{path}") unless File.exists?(path)
          raw = File.read(path)
          from_content(raw)
        rescue ex : YAML::ParseException
          # YAML::ParseException 消息自带行号列号（验收：坏 YAML 报错含行号）
          raise ConfigError.new("invalid YAML in #{path}: #{ex.message}")
        end

        # 纯函数入口（热更新管线复用）：内容 → typed Config → validate
        def from_content(raw : String) : Config
          config = Config.from_yaml(expand_env_vars(raw))
          errors = validate(config)
          raise ValidationError.new(errors) unless errors.empty?
          # 旧配置迁移指引（#214：不静默失败——加载可用，但逐条告知新形状）
          migration_hints(config).each { |hint| Log.warn { "migration hint: #{hint}" } }
          config
        rescue ex : YAML::ParseException
          raise ConfigError.new("invalid YAML: #{ex.message}")
        end

        # 环境变量展开：${VAR} 与 $VAR（autobot loader.cr:152-166 同款）
        def expand_env_vars(content : String) : String
          expand_braced = content.gsub(/\$\{([A-Z_][A-Z0-9_]*)\}/) do |whole, match|
            ENV[match[1]]? || whole
          end
          expand_braced.gsub(/\$([A-Z_][A-Z0-9_]*)/) do |whole, match|
            ENV[match[1]]? || whole
          end
        end

        # 校验器（纯函数）：返回错误列表，空数组=合法。
        # M1-WP8 热更新「先验后换」复用本函数，不在此处 raise（拒启由 from_content 负责）。
        # 会话输入调度策略校验（session-input-scheduling.md §3.4；先验后换复用）
        private def validate_session_policies(config : Config, errors : Array(String)) : Nil
          agents_policies = {} of String => Scheduling::SessionPolicyConfig?
          config.agents.each { |name, agent| agents_policies[name] = agent.session }
          errors.concat(Scheduling::Policy.validate_config_errors(config.gateway.session, agents_policies))
        end

        def validate(config : Config) : Array(String)
          errors = [] of String
          validate_providers(config, errors)
          validate_agents(config, errors)
          validate_channels(config, errors)
          validate_bindings(config, errors)
          validate_gateway(config, errors)
          validate_session_policies(config, errors)
          errors
        end

        # provider 层校验（#214）：protocol 枚举、base_url 可解析（缺省时须规格表
        # 兜底——否则装配期 ProviderResolveError 逃逸 reload 救援、留下半新半旧
        # 状态，先验后换必须在 CURRENT.set 与密钥迁移前拒掉，CodeRabbit）、
        # agent.provider 悬空引用、provider 与 provider_ref 双写冲突
        private def validate_providers(config : Config, errors : Array(String)) : Nil
          config.providers.each do |name, pcfg|
            unless {"openai-compatible", "anthropic"}.includes?(pcfg.protocol)
              errors << "providers.#{name}.protocol must be openai-compatible or anthropic (got '#{pcfg.protocol}')"
            end
            base = pcfg.base_url
            if base.nil? || base.strip.empty?
              unless Providers.spec_for(name)
                errors << "providers.#{name}: base_url missing and '#{name}' is not a known vendor (set providers.#{name}.base_url)"
              end
            end
          end
          config.agents.each do |name, agent|
            next unless pref = agent.provider
            unless config.providers.has_key?(pref)
              errors << "agents.#{name}.provider '#{pref}' references an undefined providers entry"
            end
            if legacy = agent.provider_ref
              unless legacy == pref
                errors << "agents.#{name}: provider ('#{pref}') and provider_ref ('#{legacy}') disagree; remove provider_ref"
              end
            end
          end
        end

        # 旧配置迁移指引（#214 纯函数）：旧形状合法可用（过渡支持），但逐条
        # 给出可读迁移路径；新形状配置返回空数组。loader 加载时经 Log.warn 输出。
        def migration_hints(config : Config) : Array(String)
          hints = [] of String
          config.agents.each do |name, agent|
            unless agent.provider
              if legacy = agent.provider_ref
                hints << "agents.#{name}.provider_ref is deprecated: define providers.#{legacy} { api_key, base_url, protocol } and set agents.#{name}.provider: #{legacy}"
              elsif agent.model.includes?("/") && (inferred = agent.model.split("/").first?) && !inferred.strip.empty?
                hints << "agents.#{name}.model '#{agent.model}' encodes the vendor as a prefix (legacy): define providers.#{inferred} { api_key, base_url, protocol } and set agents.#{name}.provider: #{inferred} with a bare model name"
              end
            end
            if agent.api_key
              hints << "agents.#{name}.api_key is deprecated: move it to providers.<name>.api_key (one key shared by all referencing agents; migrated to vault at gateway start)"
            end
          end
          hints
        end

        private def validate_agents(config : Config, errors : Array(String)) : Nil
          errors << "at least one agent must be defined" if config.agents.empty?
          config.agents.each do |name, agent|
            errors << "agents.#{name}.model must not be empty" if agent.model.strip.empty?
            # persona_file 悬空引用校验（M4.4-WP1：悬空引用报错可读）——
            # 相对路径基于进程 cwd 解析（与 Gateway 运行目录一致）
            if pf = agent.persona_file
              errors << "agents.#{name}.persona_file not found: #{pf}" unless File.exists?(pf)
            end
            (agent.skills || [] of String).each do |skill|
              errors << "agents.#{name}.skills entry must not be empty" if skill.strip.empty?
            end
          end
        end

        private def validate_channels(config : Config, errors : Array(String)) : Nil
          {% for ct in CHANNEL_TYPES %}
            channel = config.channels.{{ ct.id }}.try(&.accounts) || [] of {{ ct.camelcase.id }}Account
            seen = Set(String).new
            channel.each_with_index do |account, i|
              tag = "channels.{{ ct.id }}.accounts[#{i}]"
              errors << "#{tag}.id must not be empty" if account.id.strip.empty?
              errors << "#{tag}.id '#{account.id}' duplicates an earlier account id" unless seen.add?(account.id)
              validate_{{ ct.id }}_account(account, tag, errors)
            end
          {% end %}
        end

        private def validate_email_account(account : EmailAccount, tag : String, errors : Array(String)) : Nil
          errors << "#{tag}.receive must be imap-idle or gmail-api (got '#{account.receive}')" unless {"imap-idle", "gmail-api"}.includes?(account.receive)
          if account.receive == "imap-idle"
            errors << "#{tag}.platform (IMAP host) is required for imap-idle" if account.platform.nil? || account.platform.try(&.strip.empty?)
            errors << "#{tag}.credentials.user is required for imap-idle" if account.credentials["user"]?.nil?
            errors << "#{tag}.credentials.password is required for imap-idle" if account.credentials["password"]?.nil?
          end
          if smtp = account.smtp
            errors << "#{tag}.smtp.tls must be implicit, starttls or none (got '#{smtp.tls}')" unless {"implicit", "starttls", "none"}.includes?(smtp.tls)
            errors << "#{tag}.smtp.port must be 1..65535" unless (1..65535).covers?(smtp.port)
          end
        end

        private def validate_wecom_account(account : WecomAccount, tag : String, errors : Array(String)) : Nil
          errors << "#{tag}.mode must be aibot-longconn or app-callback (got '#{account.mode}')" unless {"aibot-longconn", "app-callback"}.includes?(account.mode)
          if account.mode == "aibot-longconn"
            errors << "#{tag}.credentials.corpid is required" if account.credentials["corpid"]?.nil?
            errors << "#{tag}.credentials.aibot_secret is required" if account.credentials["aibot_secret"]?.nil?
          else
            errors << "#{tag}.callback_path is required for app-callback" if account.callback_path.nil?
            {"corpid", "agentid", "token", "aes_key"}.each do |key|
              errors << "#{tag}.credentials.#{key} is required for app-callback" if account.credentials[key]?.nil?
            end
          end
        end

        private def validate_lark_account(account : LarkAccount, tag : String, errors : Array(String)) : Nil
          errors << "#{tag}.platform must not be empty (feishu.cn or larksuite.com)" if account.platform.strip.empty?
          errors << "#{tag}.receive must be ws-longconn or webhook (got '#{account.receive}')" unless {"ws-longconn", "webhook"}.includes?(account.receive)
          errors << "#{tag}.credentials.app_id is required" if account.credentials["app_id"]?.nil?
          errors << "#{tag}.credentials.app_secret is required" if account.credentials["app_secret"]?.nil?
        end

        private def validate_telegram_account(account : TelegramAccount, tag : String, errors : Array(String)) : Nil
          # bot_token 缺键由 YAML 反序列化拒绝（非空类型）；此处拦空串
          errors << "#{tag}.bot_token must not be empty" if account.bot_token.strip.empty?
          errors << "#{tag}.api_base_url must not be empty when set" if account.api_base_url.try(&.strip.empty?)
          errors << "#{tag}.token_ref must not be empty when set" if account.token_ref.try(&.strip.empty?)
        end

        private def validate_bindings(config : Config, errors : Array(String)) : Nil
          config.bindings.each_with_index do |binding, i|
            tag = "bindings[#{i}]"
            errors << "#{tag}.channel '#{binding.channel}' is not a known channel (#{CHANNEL_TYPES.join("/")})" unless CHANNEL_TYPES.includes?(binding.channel)
            errors << "#{tag}.agent '#{binding.agent}' references an undefined agent" unless config.agents.has_key?(binding.agent)
            next unless CHANNEL_TYPES.includes?(binding.channel)
            account = binding.account
            next if account.nil? || account == "*"
            unless config.channels.account_ids(binding.channel).includes?(account)
              errors << "#{tag}.account '#{account}' does not exist in channel '#{binding.channel}'"
            end
          end
        end

        private def validate_gateway(config : Config, errors : Array(String)) : Nil
          if http = config.gateway.http
            # 0 = 由系统分配空闲端口（测试与并行实例用；listen 后回写实际端口）
            errors << "gateway.http.port must be 0..65535" unless (0..65535).covers?(http.port)
            errors << "gateway.http.auth must be token, password or tailscale (got '#{http.auth}')" unless {"token", "password", "tailscale"}.includes?(http.auth)
          end
          errors << "gateway.ipc.mode must be auto, unix, tcp or off (got '#{config.gateway.ipc.mode}')" unless {"auto", "unix", "tcp", "off"}.includes?(config.gateway.ipc.mode)
          # 0 = 系统分配空闲端口（同 http.port）：spec 并行跑、同机起多个 gateway 时用
          errors << "gateway.ipc.port must be 0..65535" unless (0..65535).covers?(config.gateway.ipc.port)
          # agent 间协作防环上限（#185 WP1 §8.1）：0/负数会让所有投递被拒，先验后换即拦
          max_hops = config.gateway.collaboration.max_hops
          errors << "gateway.collaboration.max_hops must be >= 1 (got #{max_hops})" unless max_hops >= 1
        end
      end
    end
  end
end
