require "crypto/subtle"
require "digest/sha256"
require "http"
require "json"
require "../../platform/bus/bus"
require "../base"
require "../common/token_provider"

# 飞书/Lark 渠道（M1-WP5，design.md §5.6；渠道笔记 b1/b2/b4）：
# webhook 回调形态（完整落地）：challenge 应答 + X-Lark-Signature 验签
# （sha256(timestamp + nonce + encrypt_key + body)）+ 事件 id 排重（3 秒超时重推口径）。
# base_url 入账号配置（feishu.cn | larksuite.com，账号体系完全独立）。
# WS 长连接形态（主推）需官方 WS 协议帧细节，M1 先落 webhook + WS 骨架（协议核对后补全）。
module Sebas
  module Channels
    module Lark
      class LarkCallbackAdapter < ChannelAdapter
        Log = Sebas::Log.for("channels.lark")

        getter health : String

        def initialize(account : ::Sebas::Platform::Config::LarkAccount, @bus : ::Sebas::Platform::Bus::Bus,
                       @store : ::Sebas::Platform::Store::Store)
          super("lark", account.id)
          @account = account
          @health = "offline"
        end

        def credential_fingerprint : String
          ::Digest::SHA256.hexdigest("#{@account.platform}#{@account.credentials["app_id"]?}#{@account.credentials["app_secret"]?}")
        end

        def start : Nil
          @health = "online" # webhook 形态无长连接
        end

        def stop : Nil
          @health = "stopped"
        end

        def send(peer : String, content : String, idempotency_key : String? = nil) : SendResult
          SendResult.error("outbound im/v1/messages send lands with M1-WP5 real-account integration")
        end

        # URL 校验挑战 + 事件接收（3 秒内响应口径：验签+落库+入总线即返回）
        def handle_callback(request : HTTP::Request) : CallbackResult
          body = request.body.try(&.gets_to_end) || ""
          return CallbackResult.json(400, %({"error": "empty body"})) if body.empty?

          unless verify_signature(request, body)
            return CallbackResult.json(401, %({"error": "bad signature"}))
          end

          payload = JSON.parse(body)
          # URL 校验挑战（type: url_verification）
          if payload["type"]?.try(&.as_s?) == "url_verification"
            challenge = payload["challenge"]?.try(&.as_s?) || ""
            return CallbackResult.json(200, {challenge: challenge}.to_json)
          end

          dispatch_event(payload)
          CallbackResult.json(200, %({"ok": true}))
        rescue ex : ::Exception
          Log.error(exception: ex) { "lark callback error (account=#{@account.id})" }
          CallbackResult.json(500, %({"error": "internal"}))
        end

        # 推荐签名：sha256(timestamp + nonce + encrypt_key + body) vs X-Lark-Signature
        private def verify_signature(request : HTTP::Request, body : String) : Bool
          encrypt_key = @account.credentials["encrypt_key"]?
          return true unless encrypt_key # 未配 Encrypt Key 时不做签名校验（官方自评低安全，文档化取舍）

          timestamp = request.headers["X-Lark-Request-Timestamp"]?
          nonce = request.headers["X-Lark-Request-Nonce"]?
          signature = request.headers["X-Lark-Signature"]?
          return false unless timestamp && nonce && signature
          expected = ::Digest::SHA256.hexdigest(timestamp + nonce + encrypt_key + body)
          ::Crypto::Subtle.constant_time_compare(expected, signature)
        end

        # 事件 id 排重（超时重推口径）：memo 首写为准；入总线即回 200（3 秒约束）
        private def dispatch_event(payload : JSON::Any) : Nil
          event_id = payload.dig?("header", "event_id").try(&.as_s?) || ""
          unless event_id.empty?
            dedup_key = "lark:event:#{@account.id}:#{event_id}"
            return if @store.memo_get(dedup_key) == "seen" # 重复事件 id 不二投
            @store.memo_put(dedup_key, "seen")
          end

          peer = payload.dig?("event", "sender", "sender_id", "open_id").try(&.as_s?) || ""
          content = payload.dig?("event", "message", "content").try(&.as_s?) || ""
          event_type = payload.dig?("header", "event_type").try(&.as_s?) || ""
          @bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
            event_id: "lark:#{@account.id}:#{event_id.empty? ? "#{event_type}:#{Time.utc.to_unix_ms}" : event_id}",
            channel_type: "lark",
            account_id: @account.id,
            peer: peer,
            content: content
          ))
          @health = "online"
        end
      end
    end
  end
end
