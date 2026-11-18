require "yaml"

# 配置 schema（design.md §3.4 配置树；M0-WP2 承载，M1-WP1 数组化语义已在 day one 就位：
# channels.<type>.accounts[] 为数组结构，M0 仅运行单账号，M1 起多账号并存）
#
# YAML::Serializable 约定：缺省键回退到「字段声明处的内联默认值」；
# 节点类默认值引用其他节点类（如 Config.channels = Channels.new）时，被引用类
# 必须自带显式 initialize（serializable 宏会替换掉默认无参构造）。
module Sebas
  module Platform
    module Config
      # 渠道类型总表（宏样板的展开源；新增渠道在此登记）
      CHANNEL_TYPES = %w[email wecom lark]

      class Config
        include YAML::Serializable
        getter channels : Channels = Channels.new
        getter agents : Hash(String, AgentConfig) = {} of String => AgentConfig
        getter bindings : Array(BindingConfig) = [] of BindingConfig
        getter gateway : GatewayConfig = GatewayConfig.new
      end

      class Channels
        include YAML::Serializable
        getter email : EmailChannel?
        getter wecom : WecomChannel?
        getter lark : LarkChannel?

        def initialize
        end

        def account_ids(channel_type : String) : Array(String)
          case channel_type
          when "email" then email.try(&.accounts.map(&.id)) || [] of String
          when "wecom" then wecom.try(&.accounts.map(&.id)) || [] of String
          when "lark"  then lark.try(&.accounts.map(&.id)) || [] of String
          else              [] of String
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

      class AgentConfig
        include YAML::Serializable
        getter model : String
        getter provider_ref : String?
        getter persona_file : String?
        getter api_key : String? # M0 明文过渡；M1-WP7 迁 keyring
        getter memory : MemoryConfig?
        getter tools : ToolsConfig?
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
        getter data_dir : String = "data"

        def initialize(@http = nil, @ipc = IpcConfig.new, @data_dir = "data")
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
