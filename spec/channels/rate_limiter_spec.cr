require "spec"
require "../../src/channels/common/rate_limiter"

module Sebas
  describe "rate limiter (M1-WP6)" do
    it "allows the burst then backs off the next send (限流桶触发退避)" do
      limiter = Channels::Common::RateLimiter.new(2.0, 2) # 2/s, burst 2
      limiter.acquire("acc", "peer-a", 50.milliseconds).should be_true
      limiter.acquire("acc", "peer-a", 50.milliseconds).should be_true
      # 第 3 个令牌需等待 ~0.5s（退避排队可观测）
      start = Time.instant
      limiter.acquire("acc", "peer-a", 2.seconds).should be_true
      (Time.instant - start).should be > 200.milliseconds
    end

    it "isolates buckets per (account, target)" do
      limiter = Channels::Common::RateLimiter.new(2.0, 1)
      limiter.acquire("acc", "peer-a", 10.milliseconds).should be_true
      limiter.acquire("acc", "peer-b", 10.milliseconds).should be_true # 不同 target 独立建桶
      limiter.acquire("acc2", "peer-a", 10.milliseconds).should be_true
      limiter.acquire("acc", "peer-a", 50.milliseconds).should be_false # 同桶耗尽
    end

    it "queues during cooldown after upstream rate-limit errors (45009/429 口径)" do
      limiter = Channels::Common::RateLimiter.new(100.0, 10)
      limiter.cool_down("acc", "peer", 300.milliseconds)
      start = Time.instant
      limiter.acquire("acc", "peer", 2.seconds).should be_true
      (Time.instant - start).should be > 200.milliseconds # 冷却期间排队等待
    end

    it "gives up when the cooldown exceeds the timeout" do
      limiter = Channels::Common::RateLimiter.new(100.0, 10)
      limiter.cool_down("acc", "peer", 5.seconds)
      limiter.acquire("acc", "peer", 300.milliseconds).should be_false
    end

    it "provides channel presets" do
      Channels::Common::RateLimiter.wecom_member.rate.should eq(30 / 60.0)
      Channels::Common::RateLimiter.lark_peer.rate.should eq(5.0)
    end
  end
end
