require "../../log"

# 限流桶（M1-WP6，design.md §5.3.1）：按 (账号, 目标) 维度 token bucket。
# 发送前置检查，超限排队/退避；上游限流错误码（企微 45009、飞书 429/230020）→ 冷却。
module Sebas
  module Channels
    module Common
      class RateLimiter
        Log = Sebas::Log.for("sebas.channels.ratelimit")

        private record Bucket, tokens : Float64, last_refill : Time::Instant, cooling_until : Time::Instant

        getter rate : Float64
        getter burst : Int32

        @buckets = {} of Tuple(String, String) => Bucket
        @mutex = Mutex.new

        def initialize(@rate : Float64, @burst : Int32)
          raise ArgumentError.new("rate must be positive") unless @rate.positive?
          raise ArgumentError.new("burst must be positive") unless @burst.positive?
        end

        # 便捷预设（渠道笔记 §5.3.1）
        def self.wecom_member : RateLimiter
          new(30 / 60.0, 30) # 同成员 30 次/分钟
        end

        def self.lark_peer : RateLimiter
          new(5.0, 5) # 同群/同用户 5 次/秒
        end

        # 取一个令牌：有则立即返回 true；无则退避排队直到 deadline（§14 M1 验收第 4 条）
        def acquire(account_id : String, target : String, timeout : Time::Span = 5.seconds) : Bool
          deadline = Time.instant + timeout
          loop do
            wait = compute_wait(account_id, target)
            if wait.total_milliseconds <= 0
              return true
            end
            return false if Time.instant + wait > deadline
            sleep wait
          end
        end

        # 上游限流响应（企微 45009 / 飞书 429、230020）→ 冷却排队
        def cool_down(account_id : String, target : String, seconds : Time::Span = 65.seconds) : Nil
          @mutex.synchronize do
            bucket = refill(account_id, target)
            @buckets[{account_id, target}] = Bucket.new(bucket.tokens, bucket.last_refill, Time.instant + seconds)
          end
          Log.warn { "rate limiter cooling down (account=#{account_id} target=#{target} for #{seconds})" }
        end

        # 返回零等待 = 可直接取用（并扣减一个令牌）；否则返回建议等待时长。
        # 单写者池内调用（worker 串行 per session），并发正确性由内部 Mutex 保证。
        private def compute_wait(account_id : String, target : String) : Time::Span
          @mutex.synchronize do
            bucket = refill(account_id, target)
            cooling = bucket.cooling_until - Time.instant
            if cooling > Time::Span.zero
              return cooling
            end
            if bucket.tokens >= 1.0
              @buckets[{account_id, target}] = Bucket.new(bucket.tokens - 1.0, bucket.last_refill, bucket.cooling_until)
              return Time::Span.zero
            end
            Time::Span.new(nanoseconds: ((1.0 - bucket.tokens) / @rate * 1e9).to_i64)
          end
        end

        private def refill(account_id : String, target : String) : Bucket
          key = {account_id, target}
          now = Time.instant
          bucket = @buckets[key]? || Bucket.new(@burst.to_f, now, Time.instant - 1.day)
          elapsed = now - bucket.last_refill
          tokens = Math.min(@burst.to_f, bucket.tokens + elapsed.total_seconds * @rate)
          bucket = Bucket.new(tokens, now, bucket.cooling_until)
          @buckets[key] = bucket
          bucket
        end
      end
    end
  end
end
