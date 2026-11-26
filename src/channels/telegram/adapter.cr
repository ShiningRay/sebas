require "../../platform/store/store"
require "../../platform/bus/bus"
require "../base"
require "../common/rate_limiter"
require "./bot_api"
require "./long_poll"
require "../../platform/config/schema"

# Telegram 渠道适配器（M3-WP8）：getUpdates long-poll 收信 + sendMessage 出站。
# fiber-per-account（§5.1）；限流双桶：按 (account_id, chat_id) 1 msg/s、
# 全局 30 msg/s（官方 FAQ，m8 提案 §4.3）。恢复扫描与双模状态机在 LongPoll。
module Sebas
  module Channels
    module Telegram
      class TelegramChannelAdapter < ChannelAdapter
        Log = Sebas::Log.for("channels.telegram")

        getter health : String

        # 单 chat 1 msg/s（burst=1 不积攒）；全局 30 msg/s
        PEER_RATE   =  1.0
        GLOBAL_RATE = 30.0

        # Telegram sendMessage 文本上限（官方 Bot API 文档）
        TEXT_LIMIT = 4096

        def initialize(account : Platform::Config::TelegramAccount, @bus : ::Sebas::Platform::Bus::Bus,
                       @store : ::Sebas::Platform::Store::Store,
                       poll_timeout : Int32 = 50, reset_after : ::Time::Span = LongPoll::RESET_AFTER,
                       scan_interval : ::Time::Span = 60.seconds, backoff : ::Time::Span = 5.seconds,
                       api : BotApi? = nil, clock : -> ::Time = -> { ::Time.utc },
                       @send_api_factory : Proc(BotApi)? = nil)
          super("telegram", account.id)
          @account = account
          @api = api || BotApi.new(account.bot_token, account.api_base_url, poll_timeout: poll_timeout)
          @poll = LongPoll.new(account.id, @api, @store, @bus, clock: clock)
          @reset_after = reset_after
          @scan_interval = scan_interval
          @backoff = backoff
          @peer_limiter = Common::RateLimiter.new(PEER_RATE, 1)
          @global_limiter = Common::RateLimiter.new(GLOBAL_RATE, 30)
          @running = Atomic(Bool).new(false)
          @health = "offline"
        end

        # 启动收信循环（幂等防御重复 start；每账号一条 long-poll fiber——多账号
        # 各自独立轮询互不串扰，状态按 account_id 隔离于 telegram_accounts 表）
        def start : Nil
          return if @running.swap(true)
          spawn(name: "sebas-account:telegram:#{@account.id}") do
            @poll.run(@running, scan_interval: @scan_interval, backoff: @backoff)
          rescue ex : ::Exception
            @health = "degraded"
            Log.error(exception: ex) { "telegram poll loop crashed (account=#{@account.id})" }
          end
          @health = "online"
        end

        def stop : Nil
          @running.set(false)
          # 退出由 poll 循环下轮感知；long-poll 挂起最多一个 timeout 周期
        end

        # 出站：先全局桶再单 chat 桶（两者都取到才发；超时返回 error 不丢任务——
        # 调用方按 SendResult 决定重试，§5.3.1 限流排队不丢）。超长文本按
        # 4096 字符上限切分多条依次发送（每条都过限流桶）。
        #
        # 出站走独立 BotApi（每次新建 client，对齐 email smtp_client 惯例）：
        # 共享 client 同时被 long-poll fiber（挂起至 poll_timeout）与 send
        # fiber 并发读写，HTTP::Client 非线程安全，响应会串线。
        def send(peer : String, content : String, idempotency_key : String? = nil) : SendResult
          message_id : String? = nil
          split_message(content).each do |chunk|
            # 先单 chat 桶（可能等待冷却）再全局限流：全局许可紧贴实际发送时刻
            # 取得，避免「先取全局、等待期间桶再补充、实际发送超全局速率」的
            # 顺序性超限（全局限流必须约束发送瞬间而非调用瞬间）
            unless @peer_limiter.acquire(@account.id, peer, 10.seconds)
              return SendResult.error("telegram peer rate limit (1 msg/s) wait timeout")
            end
            unless @global_limiter.acquire(@account.id, "*", 10.seconds)
              return SendResult.error("telegram global rate limit (30 msg/s) wait timeout")
            end
            message_id = send_api.send_message(peer, chunk)
          end
          Log.info { "telegram sent (account=#{@account.id}, chat=#{peer}, key=#{idempotency_key || "none"})" }
          SendResult.success(message_id)
        rescue ex : BotApiError
          # 上游 429 → 冷却重试（同 chat 1 msg/s 已限流，仍可被服务端判限）
          @peer_limiter.cool_down(@account.id, peer) if ex.error_code == 429
          Log.error { "telegram send failed: #{ex.message}" }
          SendResult.error(ex.message || ex.class.to_s)
        end

        # 超长文本切分（按字符计——Telegram 上限是 UTF-8 字符数不是字节数）
        private def split_message(content : String) : Array(String)
          return [content] if content.size <= TEXT_LIMIT
          content.each_char.each_slice(TEXT_LIMIT).map(&.join).to_a
        end

        private def send_api : BotApi
          @send_api_factory.try(&.call) || BotApi.new(@account.bot_token, @account.api_base_url)
        end

        # 轮询状态机（spec 与管理面观测入口）
        def poll : LongPoll
          @poll
        end
      end
    end
  end
end
