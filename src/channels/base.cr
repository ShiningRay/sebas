# 渠道适配层（M0-WP4）：abstract ChannelAdapter——每账号一个 adapter fiber
# （design.md §4.1/§5.2；两形态归并：长连接型/回调型；M0 落 email，M1 落企微/飞书）
require "http"

module Sebas
  module Channels
    Log = Sebas::Log.for("channels")

    # 回调入站结果（§5.2 回调面共享监听）
    record CallbackResult, status : Int32, body : String, content_type : String do
      def self.json(status : Int32, body : String) : CallbackResult
        new(status, body, "application/json")
      end

      def self.plain(status : Int32, body : String) : CallbackResult
        new(status, body, "text/plain")
      end
    end

    # 出站投递结果（typed rescue 转值）
    record SendResult, ok : Bool, message_id : String?, error : String? do
      def self.success(message_id : String? = nil) : SendResult
        new(true, message_id, nil)
      end

      def self.error(message : String) : SendResult
        new(false, nil, message)
      end

      def ok? : Bool
        ok
      end
    end

    abstract class ChannelAdapter
      getter account_id : String
      getter channel_type : String

      def initialize(@channel_type : String, @account_id : String)
      end

      # 凭据指纹（重复凭据检测 park 口径，§5.1/§10.1）：默认 account_id
      def credential_fingerprint : String
        account_id
      end

      # 启动收信循环（fiber-per-account；实现须幂等防御重复 start）
      abstract def start : Nil

      # 优雅停止：drain 在途消息后 close（§11.3 账号删除行）
      abstract def stop : Nil

      # 出站发送。idempotency_key 由调用方（工具执行器，M0-WP6）携带；
      # 渠道层不自行排重，幂等三件套的提交级在 intents、工具级在 registry。
      abstract def send(peer : String, content : String, idempotency_key : String? = nil) : SendResult

      # 健康状态（§5.1 监督体上报；M1-WP2 起 TUI 可查）
      def health : String
        "unknown"
      end

      def handle_callback(request : HTTP::Request) : CallbackResult
        CallbackResult.plain(404, "callback not supported by this adapter")
      end
    end
  end
end
