require "json"
require "semantic_version"

# 插件 manifest（M3-WP4，#16；design.md §12.2/§12.6）：安装/装载期 fail-closed
# 校验。id/版本/词法/钩子闭集/超时上限逐条验，非法即拒绝装载——manifest 是
# 授权上限（actions/hooks/capabilities），解析失败或字段越界都不得静默放行。
module Sebas
  module Plugins
    class ManifestError < ::Exception; end

    # 首版钩子闭集（§12.11；gateway.start 与 gateway.stop 是两个独立名称）。
    # manifest.hooks 出现闭集外的名称 = 声明越权，装载即拒。
    KNOWN_HOOKS = %w[
      message.received
      message.sending
      message.sent
      agent.turn.before
      agent.turn.after
      llm.request.before
      llm.request.after
      llm.request.error
      llm.response.transform
      tool.call.before
      tool.call.after
      tool.result.transform
      session.start
      session.end
      session.compact.before
      session.compact.after
      memory.remember.before
      memory.remember.after
      task.start
      task.end
      gateway.start
      gateway.stop
    ]

    # 生命周期动作（§12.3）：仅由宿主在生命周期节点显式调用，绝不作为工具
    # 注册给 agent，也绝不被 hook 派发路径隐式触发。
    LIFECYCLE_ACTIONS = %w[install enable disable]

    class Manifest
      include JSON::Serializable

      getter schema_version : Int32
      getter id : String
      getter version : String
      getter api_version : String
      getter entrypoint : String?
      getter provides : Array(String)?
      getter actions : Array(String)?
      getter hooks : Array(String)?
      getter capabilities : Array(String)?
      getter timeout_ms : Int64?
      getter config_schema : JSON::Any?

      # 宿主支持的插件 API 主版本（§12.6：api_version 为主版本兼容契约）。
      SUPPORTED_API_MAJOR = "1"

      # 单值长度上限（§12.6：id 1..64；其余名称同口径防滥用）
      NAME_MAX = 64

      def actions_list : Array(String)
        @actions || [] of String
      end

      def hooks_list : Array(String)
        @hooks || [] of String
      end

      def capabilities_list : Array(String)
        @capabilities || [] of String
      end

      def provides_list : Array(String)
        @provides || [] of String
      end

      def declares_action?(name : String) : Bool
        actions_list.includes?(name)
      end

      def declares_hook?(name : String) : Bool
        hooks_list.includes?(name)
      end

      def declares_capability?(name : String) : Bool
        capabilities_list.includes?(name)
      end

      # 生命周期动作不进 agent 工具面（§12.3：宿主显式调用，无隐式 init）
      def tool_actions : Array(String)
        actions_list.reject { |a| LIFECYCLE_ACTIONS.includes?(a) }
      end

      def self.parse(text : String) : Manifest
        manifest = begin
          from_json(text)
        rescue ex : JSON::ParseException | JSON::SerializableError
          raise ManifestError.new("invalid manifest JSON: #{ex.message}")
        end
        manifest.validate!
        manifest
      end

      def validate! : Nil
        # 必填字段（schema_version/id/version/api_version）缺失由
        # JSON::Serializable 在 from_json 时直接抛出，这里只做语义校验。
        unless /\A[a-z][a-z0-9-]{0,63}\z/.matches?(id)
          raise ManifestError.new("manifest id must be lowercase [a-z][a-z0-9-]* of 1..64 chars (got '#{id}')")
        end
        begin
          SemanticVersion.parse(version)
        rescue ex : ArgumentError
          raise ManifestError.new("manifest version must be SemVer (got '#{version}'): #{ex.message}")
        end
        unless /\A\d+\z/.matches?(api_version)
          raise ManifestError.new("manifest api_version must be a major version number (got '#{api_version}')")
        end
        unless api_version == SUPPORTED_API_MAJOR
          raise ManifestError.new("unsupported plugin api_version #{api_version} (host supports #{SUPPORTED_API_MAJOR})")
        end
        validate_names!("actions", actions_list)
        validate_names!("capabilities", capabilities_list)
        validate_names!("provides", provides_list)
        validate_hooks!
        if entry = @entrypoint
          validate_entrypoint!(entry)
        end
        if timeout = @timeout_ms
          unless (1..600_000).covers?(timeout)
            raise ManifestError.new("manifest timeout_ms must be 1..600000 (got #{timeout})")
          end
        end
        if schema = @config_schema
          unless schema.as_h?
            raise ManifestError.new("manifest config_schema must be an object")
          end
        end
      end

      # 名称类数组字段：非空字符串、词法安全（字母/数字/连字符/点/下划线/
      # 冒号）、无重复——重复声明 = 配置歧义，报错不去重。
      private def validate_names!(field : String, values : Array(String)) : Nil
        seen = Set(String).new
        values.each_with_index do |value, i|
          unless (1..NAME_MAX).covers?(value.size) && /\A[a-zA-Z0-9][a-zA-Z0-9._:\-]*\z/.matches?(value)
            raise ManifestError.new("manifest #{field}[#{i}] must match [a-zA-Z0-9][a-zA-Z0-9._:-]* of 1..64 chars (got '#{value}')")
          end
          unless seen.add?(value)
            raise ManifestError.new("manifest #{field}[#{i}] '#{value}' duplicates an earlier entry")
          end
        end
      end

      # 钩子名必须命中 §12.11 闭集：闭集外 = 越权声明宿主未定义的注入点。
      private def validate_hooks! : Nil
        hooks_list.each_with_index do |hook, i|
          unless KNOWN_HOOKS.includes?(hook)
            raise ManifestError.new("manifest hooks[#{i}] '#{hook}' is not in the first-version hook catalog (§12.11)")
          end
        end
      end

      # entrypoint 必须是包内相对路径：拒绝绝对路径与 .. 穿越（§12.6 包布局）。
      # 词法判定跨平台成立——Path#absolute? 在 Windows 不认无盘符的 "/x"。
      private def validate_entrypoint!(entry : String) : Nil
        unless (1..NAME_MAX * 4).covers?(entry.size)
          raise ManifestError.new("manifest entrypoint too long")
        end
        if entry.starts_with?('/') || entry.starts_with?('\\') ||
           (entry.size >= 2 && entry[1] == ':')
          raise ManifestError.new("manifest entrypoint must be a relative path inside the package (got '#{entry}')")
        end
        if entry.gsub("\\", "/").split("/").includes?("..")
          raise ManifestError.new("manifest entrypoint must not traverse outside the package (got '#{entry}')")
        end
        unless entry.ends_with?(".rb")
          raise ManifestError.new("manifest entrypoint must be a .rb script (got '#{entry}')")
        end
      end
    end

    # 已装载插件：manifest + 包目录。脚本内容每次调用从盘读取（§12.5 开发
    # 语义：改脚本只影响新调用）；manifest 在装载期解析并缓存。
    record LoadedPlugin, dir : Path, manifest : Manifest do
      def entry_file : Path
        dir / (manifest.entrypoint || "plugin.rb")
      end

      def id : String
        manifest.id
      end
    end
  end
end
