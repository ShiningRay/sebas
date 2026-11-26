require "http"
require "json"
require "digest/sha256"

# Telegram Bot API HTTP 客户端（M3-WP8）：getUpdates long-poll + sendMessage。
# api_base_url 账号级可配（自建反代；缺省官方 api.telegram.org，m8 提案 §4.1）。
# 仅覆盖 M3-WP8 所需两个方法；错误响应（ok=false）抛 BotApiError 由上层退避。
module Sebas
  module Channels
    module Telegram
      class BotApiError < ::Exception
        getter error_code : Int32?

        def initialize(message : String, @error_code : Int32? = nil)
          super(message)
        end
      end

      record Update,
        update_id : Int64,
        raw_payload : String,
        content_fingerprint : String,
        chat_id : String?,
        message_id : String?,
        text : String? do
        # 入站 event_id 确定性派生（m8 提案 §4.2，唯一形式）：
        # `tg:<account_id>:<sha256(update_id || ":" || content_fingerprint)>`——
        # update_id 与内容指纹同时纳入：空闲重置后 Telegram 可能复用相同
        # update_id，纯 (account_id, update_id) 派生会让内容不同的两条 update
        # 得到相同 event_id，新消息被 intent 排重静默跳过。所有投递路径
        # （首次/启动恢复/周期扫描）按同一规则重建，同值。
        def event_id(account_id : String) : String
          "tg:#{account_id}:#{Digest::SHA256.hexdigest("#{update_id}:#{content_fingerprint}")}"
        end
      end

      class BotApi
        DEFAULT_BASE_URL = "https://api.telegram.org"

        # long-poll 服务器侧挂起时长（官方推荐 50；NAT/反代易掐空闲连接——
        # 不低于 30 不高于 60，WBS M3-WP8 风险条）
        getter poll_timeout : Int32

        @client : ::HTTP::Client

        # http：测试注入点（mock server）；缺省按 base_url 自建
        def initialize(token : String, base_url : String? = nil, poll_timeout : Int32 = 50,
                       connect_timeout : Time::Span = 10.seconds, read_timeout : Time::Span? = nil,
                       @http : ::HTTP::Client? = nil)
          raise ArgumentError.new("bot token must not be empty") if token.empty?
          @poll_timeout = poll_timeout
          @base = (base_url || DEFAULT_BASE_URL).rstrip('/')
          if client = @http
            @client = client
          else
            uri = ::URI.parse(@base)
            @client = ::HTTP::Client.new(uri)
            @client.connect_timeout = connect_timeout
            @client.read_timeout = read_timeout || (poll_timeout.seconds + 15.seconds)
          end
          @token = token
        end

        def close : Nil
          @client.close unless @http # 注入客户端归调用方管理
        end

        def base_url : String
          @base
        end

        # getUpdates long-poll。offset：确认游标（最后确认 update_id + 1）；
        # nil = 重置模式/首次拉取（不传 offset，拉未确认全集，提案 §4.2 重置模式轮询）。
        # 返回按 update_id 升序（服务端保证）。
        def get_updates(offset : Int64?) : Array(Update)
          params = {"timeout" => @poll_timeout.to_s}
          params["offset"] = offset.to_s if offset
          request("getUpdates", params).as_a.map { |entry| BotApi.parse_update(entry) }
        end

        # sendMessage 出站（提案 §4.6：chat_id 直接投递；限流在 adapter 层 token bucket）
        # 返回 message_id（服务端定位 ID；发送侧幂等键由调用方携带，本层不排重——§4.4）
        def send_message(chat_id : String, text : String) : String?
          request("sendMessage", {"chat_id" => chat_id, "text" => text})
            .dig?("message_id").try(&.to_s)
        end

        private def request(method : String, params : Hash(String, String)) : ::JSON::Any
          path = "/bot#{@token}/#{method}"
          form = ::URI::Params.encode(params)
          response = @client.post(path, ::HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}, form)
          body = response.body
          unless response.status.success?
            raise BotApiError.new("#{method} http #{response.status.code}", response.status.code)
          end
          data = ::JSON.parse(body)
          unless data["ok"]?.try(&.as_bool?)
            raise BotApiError.new(
              "#{method} failed: #{data["description"]?.try(&.as_s?) || "unknown error"}",
              data["error_code"]?.try(&.as_i?))
          end
          data["result"]
        rescue ex : BotApiError
          raise ex
        rescue ex : IO::Error | ::Socket::Error
          raise BotApiError.new("#{method} transport error: #{ex.message}")
        rescue ex : ::JSON::ParseException
          raise BotApiError.new("#{method} non-JSON response: #{ex.message}")
        end

        # update 解析（类方法：event_id 派生是确定性契约面，恢复扫描与 spec
        # 共用同一入口）。message 缺失（非消息类 update，如 callback_query）→
        # chat_id/message_id/text 为 nil，适配器侧仍落库推进 offset 但不入总线
        # （无内容可投，落库时直接置 dispatched，见 long_poll.cr 注释）。
        # 指纹取 message 对象原文（同一 update 重推字节相同；不同 update 因
        # message_id 不同指纹必异）。
        def self.parse_update(entry : ::JSON::Any) : Update
          update_id = entry["update_id"].as_i64
          raw = entry.to_json
          message = entry["message"]?
          chat_id = message.try { |node| node.dig?("chat", "id").try(&.to_s) }
          message_id = message.try { |node| node["message_id"]?.try(&.to_s) }
          text = message.try { |node| node["text"]?.try(&.as_s?) || node["caption"]?.try(&.as_s?) }
          fingerprint = Digest::SHA256.hexdigest(message ? message.to_json : raw)
          Update.new(update_id, raw, fingerprint, chat_id, message_id, text)
        end
      end
    end
  end
end
