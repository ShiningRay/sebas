require "digest/sha1"
require "json"
require "../../platform/bus/bus"
require "../base"
require "../common/token_provider"
require "./crypto"
require "../../platform/store/store"

# 企微渠道（M1-WP4）：自建应用回调形态（完整落地，协议已核对）+ AIBot 长连接骨架
# （§15.1.1：AIBot 主动发消息 API 未逐页核对——开工首日核对后补主路实现）。
# 回调：验签 → 解密 → receiveid 校验 → msgid 排重（重试 3 次口径）→ 入总线，5 秒内响应。
module Sebas
  module Channels
    module Wecom
      class WecomCallbackAdapter < ChannelAdapter
        Log = Sebas::Log.for("sebas.channels.wecom")

        getter crypto : WecomCrypto
        getter health : String

        def initialize(account : ::Sebas::Platform::Config::WecomAccount, @bus : ::Sebas::Platform::Bus::Bus,
                       @store : ::Sebas::Platform::Store::Store)
          super("wecom", account.id)
          @account = account
          @crypto = WecomCrypto.new(
            account.credentials["token"]? || "",
            account.credentials["aes_key"]? || "",
            account.credentials["corpid"]? || ""
          )
          @health = "offline"
        end

        def credential_fingerprint : String
          Digest::SHA1.hexdigest("#{@account.credentials["corpid"]?}#{@account.credentials["aes_key"]?}")
        end

        def start : Nil
          @health = "online" # 回调形态无长连接：HTTP 面可用即可响应
        end

        def stop : Nil
          @health = "stopped"
        end

        def send(peer : String, content : String, idempotency_key : String? = nil) : SendResult
          # 主动发送：message/send 接口（agentid 必填）；secret 走 TokenProvider。
          # AIBot 主路待 §15.1.1 首日核对——此处实现自建应用 message/send 兜底。
          token = @token_provider.try(&.token.value)
          return SendResult.error("token provider not configured") if token.nil?
          SendResult.error("outbound send requires M1-WP4 首日 API 核对（§15.1.1）") # 占位：不静默失败
        end

        def with_token_provider(provider : Common::TokenProvider) : self
          @token_provider = provider
          self
        end

        # GET URL 验证（1 秒内回显明文）；POST 消息/事件（5 秒内响应）
        def handle_callback(request : HTTP::Request) : CallbackResult
          query = request.query_params
          case request.method
          when "GET"
            verify_url(query)
          else
            receive_message(request, query)
          end
        rescue ex : CryptoError
          Log.error { "callback crypto failed (account=#{@account.id}): #{ex.message}" }
          CallbackResult.json(403, %({"error": "#{ex.message}"}))
        rescue ex : ::Exception
          Log.error(exception: ex) { "callback error (account=#{@account.id})" }
          CallbackResult.json(500, %({"error": "internal"}))
        end

        private def verify_url(query : HTTP::Params) : CallbackResult
          signature = query["msg_signature"]?
          timestamp = query["timestamp"]?
          nonce = query["nonce"]?
          echostr = query["echostr"]?
          return CallbackResult.json(400, %({"error": "missing params"})) unless signature && timestamp && nonce && echostr
          return CallbackResult.json(401, %({"error": "bad signature"})) unless @crypto.verify_signature(signature, timestamp, nonce, echostr)
          msg = @crypto.decrypt(echostr, @account.credentials["corpid"]? || "")
          CallbackResult.plain(200, msg) # 明文回显（不带引号/换行）
        end

        private def receive_message(request : HTTP::Request, query : HTTP::Params) : CallbackResult
          encrypt = extract_encrypt(request)
          return CallbackResult.json(400, %({"error": "missing encrypt"})) if encrypt.nil?
          signature = query["msg_signature"]?
          timestamp = query["timestamp"]?
          nonce = query["nonce"]?
          return CallbackResult.json(400, %({"error": "missing params"})) unless signature && timestamp && nonce
          return CallbackResult.json(401, %({"error": "bad signature"})) unless @crypto.verify_signature(signature, timestamp, nonce, encrypt)

          xml = @crypto.decrypt(encrypt, @account.credentials["corpid"]? || "")
          dispatch_inbound(parse_callback_xml(xml))
        end

        private def extract_encrypt(request : HTTP::Request) : String?
          body = request.body.try(&.gets_to_end) || ""
          payload = JSON.parse(body.empty? ? "{}" : body)
          payload["encrypt"]?.try(&.as_s?)
        end

        # msgid 排重（企微重试 3 次口径）：memo 首写为准，重复投递直接 200 不重发
        private def dispatch_inbound(fields : Hash(String, String)) : CallbackResult
          msg_id = fields["msgid"]? || fields["msgid"]? || ""
          event_type = fields["event_type"]? || fields["eventtype"]? || ""

          unless msg_id.empty?
            dedup_key = "wecom:msgid:#{@account.id}:#{msg_id}"
            if @store.memo_get(dedup_key) == "seen"
              return CallbackResult.json(200, %({"ok": true}))
            end
            @store.memo_put(dedup_key, "seen")
          end

          peer = fields["from"]? || fields["fromusername"]? || ""
          content = fields["text"]? || fields["content"]? || ""
          event_id = "wecom:#{@account.id}:#{msg_id.empty? ? "#{event_type}:#{Time.utc.to_unix_ms}" : msg_id}"
          @bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
            event_id: event_id,
            channel_type: "wecom",
            account_id: @account.id,
            peer: peer,
            content: content
          ))
          @health = "online"
          CallbackResult.json(200, %({"ok": true}))
        end

        # 企微回调 XML 极简字段抽取；先剥外层 <xml> 包裹（否则整包被吞成一个字段）
        private def parse_callback_xml(xml : String) : Hash(String, String)
          fields = Hash(String, String).new
          stripped = xml.strip
          stripped = stripped[5..] if stripped.starts_with?("<xml>")
          stripped = stripped[0..-7] if stripped.ends_with?("</xml>")
          stripped.scan(/<(\w+)>(?:<!\[CDATA\[(.*?)\]\]>|(.*?))<\/\1>/m) do |match|
            fields[match[1].downcase] = match[2]? || match[3] || ""
          end
          fields
        end
      end
    end
  end
end
