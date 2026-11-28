require "yaml"
require "../../sessions/scheduling/policy"

# 配置 schema（design.md §3.4 配置树；M0-WP2 承载，M1-WP1 数组化语义已在 day one 就位：
# channels.<type>.accounts[] 为数组结构，M0 仅运行单账号，M1 起多账号并存）
#
# YAML::Serializable 约定：缺省键回退到「字段声明处的内联默认值」；
# 节点类默认值引用其他节点类（如 Config.channels = Channels.new）时，被引用类
# 必须自带显式 initialize（serializable 宏会替换掉默认无参构造）。
module Sebas
  module Platform
    module Config
      alias SessionPolicyConfig = ::Sebas::Sessions::Scheduling::SessionPolicyConfig

      # 渠道类型总表（宏样板的展开源；新增渠道在此登记）
      # telegram 为 M3-WP7 扩展点定稿先行登记（m8 提案 §4.1）：schema/绑定校验已生效，
      # 适配器接线属 M8.1-WP3（接入实现前配置可校验但无收发）。
      CHANNEL_TYPES = %w[email wecom lark telegram]

      class Config
        include YAML::Serializable
        getter channels : Channels = Channels.new
        # provider 层（#214）：厂商级配置（密钥/base_url/protocol），agent 按名引用、
        # 多 agent 共享一份密钥；热更新整根替换，密钥轮换下个 turn 生效
        getter providers : Hash(String, ProviderConfig) = {} of String => ProviderConfig
        getter agents : Hash(String, AgentConfig) = {} of String => AgentConfig
        getter bindings : Array(BindingConfig) = [] of BindingConfig
        getter gateway : GatewayConfig = GatewayConfig.new
        getter plugins : PluginsConfig = PluginsConfig.new

        # 热更新整根替换需要可空构造（CURRENT 初始占位）
        def initialize
        end
      end

      class Channels
        include YAML::Serializable
        getter email : EmailChannel?
        getter wecom : WecomChannel?
        getter lark : LarkChannel?
        getter telegram : TelegramChannel?

        def initialize
        end

        def account_ids(channel_type : String) : Array(String)
          case channel_type
          when "email"    then email.try(&.accounts.map(&.id)) || [] of String
          when "wecom"    then wecom.try(&.accounts.map(&.id)) || [] of String
          when "lark"     then lark.try(&.accounts.map(&.id)) || [] of String
          when "telegram" then telegram.try(&.accounts.map(&.id)) || [] of String
          else                 [] of String
          end
        end
      end

      # 各渠道账号壳层：accounts[] 数组（§3.4），由宏按 CHANNEL_TYPES 批量生成
      {% for ct in CHANNEL_TYPES %}
        class {{ ct.camelcase.id }}Channel
          include YAML::Serializable
          getter accounts : Array({{ ct.camelcase.id }}Account) = [] of {{ ct.camelcase.id }}Account
        end
      {% end %}

      abstract class AccountBase
        include YAML::Serializable
        getter id : String
      end

      class EmailAccount < AccountBase
        getter platform : String?
        getter receive : String = "imap-idle" # imap-idle | gmail-api（§5.4）
        getter smtp : SmtpConfig?
        getter credentials : Hash(String, String) = {} of String => String
      end

      class SmtpConfig
        include YAML::Serializable
        getter port : Int32 = 465
        getter tls : String = "implicit" # implicit | starttls | none
      end

      class WecomAccount < AccountBase
        getter mode : String = "aibot-longconn" # aibot-longconn | app-callback（§5.5）
        getter callback_path : String?
        getter credentials : Hash(String, String) = {} of String => String
      end

      class LarkAccount < AccountBase
        getter platform : String                # feishu.cn | larksuite.com（base_url 必须入账号配置 §5.6）
        getter receive : String = "ws-longconn" # ws-longconn | webhook
        getter credentials : Hash(String, String) = {} of String => String
      end

      # Telegram（M3-WP7 扩展点定稿，m8 提案 §4.1/§4.3）：bot_token 必填（缺键 YAML
      # 解析即报）、api_base_url 可选（自建 Bot API server，缺省官方 api.telegram.org）、
      # token_ref 为 keyring 指针（按 (channel_type, account_id) 命名空间存取）。
      # 适配器接线属 M8.1-WP3；接入前配置可校验、发送时 Registry 查无适配器 fail-loud。
      class TelegramAccount < AccountBase
        getter bot_token : String
        getter api_base_url : String?
        getter token_ref : String?
      end

      # provider 层配置（#214）：密钥/base_url/protocol 归厂商命名空间；
      # api_key 明文仅过渡，Gateway#migrate_secrets 迁 vault 后经 setter 抹除
      # （同 AgentConfig 纪律，配置树不留明文凭据）
      class ProviderConfig
        include YAML::Serializable
        getter api_key : String?
        setter api_key : String?
        getter base_url : String?                      # 缺省回退规格表（Providers::SPEC_TABLE）
        getter protocol : String = "openai-compatible" # openai-compatible | anthropic
      end

      class AgentConfig
        include YAML::Serializable
        getter model : String
        # 引用 providers.<name>（#214）：显式厂商层，设值后 model 即裸模型名
        # 直传（不再从 `<provider>/` 前缀推断厂商；openrouter 等自带斜杠的
        # 模型 ID 因此不受影响）
        getter provider : String?
        getter provider_ref : String? # 兼容字段（#214 前旧写法），provider 缺省时才生效
        getter persona_file : String?
        getter api_key : String? # 遗留过渡（#214：新配置用 providers.<p>.api_key）；运行期即时抹除（迁 vault），见 Gateway#migrate_secrets
        # 迁移抹除入口（M4.2-WP4）：Gateway#migrate_secrets 把明文写入 vault
        # 后经此置 nil——配置树不留明文凭据（Q6 裁断：不留 M4.4）。
        setter api_key : String?
        getter memory : MemoryConfig?
        getter tools : ToolsConfig?
        # skills 引用（M4.4-WP1 双轨统一前置）：SKILL.md 名称列表（skills/
        # 目录发现机制消费；nil = 不限定，继承全局 skills 目录全量注入）
        getter skills : Array(String)?
        # 会话输入调度定向覆盖（session-input-scheduling.md §3.1；nil = 全继承 gateway.session）
        getter session : SessionPolicyConfig?
        # 管理面筛选/聚合元数据（M4x-WP1，#147）：category 单值可空、tags 多值
        # 缺省空数组；格式校验见 Loader#validate_agents（热更新先验后换复用同一校验）
        getter category : String?
        getter tags : Array(String) = [] of String
      end

      class MemoryConfig
        include YAML::Serializable
        getter window : Int32 = 50
      end

      class ToolsConfig
        include YAML::Serializable
        getter allow : Array(String) = ["*"]
      end

      class BindingConfig
        include YAML::Serializable
        getter channel : String
        getter account : String? # 省略仅匹配该渠道默认账号（§3.2）
        getter peer : String?
        getter agent : String
      end

      class GatewayConfig
        include YAML::Serializable
        getter http : HttpConfig?
        getter ipc : IpcConfig = IpcConfig.new
        # data_dir 省略（nil）= 解析期取 <home>/data（M5.0-WP3 sebas-home.md §2.2）；
        # 显式值保持原样（相对值由消费方相对实际配置文件目录解析），不向配置树
        # 注入机器相关绝对路径——热更新仍比较配置本身的语义
        getter data_dir : String?
        # 会话输入调度系统级默认（session-input-scheduling.md §3.1；作用于所有支持对话调度的 agent）
        getter session : SessionPolicyConfig?
        # agent 间协作（design.md §8.1）：max_hops = 一轮交换内 agent-to-agent 传递上限
        getter collaboration : CollaborationConfig = CollaborationConfig.new

        def initialize(@http = nil, @ipc = IpcConfig.new, @data_dir = nil, @session = nil,
                       @collaboration = CollaborationConfig.new)
        end
      end

      # 插件面（M3-WP4，#16；design.md §12）：dir 缺省 = 插件面关闭（不扫描
      # 不注册）；interpreter 缺省取 PATH 上的 mruby。目录直扫为开发/源码
      # 布局，包格式与版本指针归 M3-WP6。
      class PluginsConfig
        include YAML::Serializable
        getter dir : String?
        getter interpreter : String?
        getter interpreter_args : Array(String)?
        # OS 资源约束（M3-WP5，#17 §12.4 ②）：可省（nil = 不设限，行为同
        # WP4）；配置即传给 Runner 生产装配（POSIX ulimit 包装 / Windows
        # Job 内存上限），非法值 fail-closed 拒绝启动
        getter memory_mb : Int64?
        getter cpu_seconds : Int32?

        def initialize(@dir = nil, @interpreter = nil, @interpreter_args = nil,
                       @memory_mb = nil, @cpu_seconds = nil)
        end
      end

      # agent 间协作参数（#185 WP1 接线）：默认 4 与 design.md §8.1 防环上限一致
      class CollaborationConfig
        include YAML::Serializable
        getter max_hops : Int64 = 4_i64

        def initialize(@max_hops = 4_i64)
        end
      end

      class HttpConfig
        include YAML::Serializable
        getter bind : String = "127.0.0.1"
        getter port : Int32 = 18790
        getter auth : String = "token" # token | password | tailscale（§9.1 子集）
      end

      class IpcConfig
        include YAML::Serializable
        getter mode : String = "auto" # auto | unix | tcp | off
        getter path : String?
        getter host : String = "127.0.0.1"
        getter port : Int32 = 18791

        def initialize(@mode = "auto", @path = nil, @host = "127.0.0.1", @port = 18791)
        end
      end
    end
  end
end
