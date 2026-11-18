require "spec"
require "http/server"
require "../../src/platform/bus/bus"
require "../../src/agents/pool"
require "../../src/providers/providers"
require "../../src/providers/pool"
require "../../src/providers/fake_provider"

# spec 助手：轮询等待条件成立（默认 5s 超时）
def wait_for(seconds : Time::Span = 5.seconds, &condition : -> Bool) : Bool
  deadline = Time.monotonic + seconds
  until Time.monotonic > deadline
    return true if condition.call
    sleep 10.milliseconds
  end
  condition.call
end

module Sebas
  describe "bus + agent worker pool + providers (M0-WP5)" do
    it "carries account context in inbound events" do
      bus = Platform::Bus::Bus.new(4)
      bus.publish(Platform::Bus::InboundMessage.new(
        "evt-1", "email", "personal-gmail", "peer@example.com", "hello"
      ))
      event = bus.receive
      case event
      when Platform::Bus::InboundMessage
        event.account_id.should eq("personal-gmail")
        event.channel_type.should eq("email")
        event.content.should eq("hello")
      else
        fail("expected InboundMessage")
      end
      bus.close
    end

    it "applies backpressure: publish blocks when the bounded bus is full" do
      bus = Platform::Bus::Bus.new(2)
      bus.publish(Platform::Bus::InboundMessage.new("e1", "email", "a", "p", "1"))
      bus.publish(Platform::Bus::InboundMessage.new("e2", "email", "a", "p", "2"))
      released = Channel(Nil).new
      spawn do
        bus.publish(Platform::Bus::InboundMessage.new("e3", "email", "a", "p", "3"))
        released.send(nil)
      end
      # 第 3 条发布应阻塞（背压）
      select
      when released.receive
        fail("publish should block on a full bus")
      when timeout 150.milliseconds
      end
      bus.receive # 消费一条，腾出空间
      select
      when released.receive
      when timeout 2.seconds
        fail("publish should unblock after consumption")
      end
      bus.close
    end

    it "keeps two concurrent sessions non-blocking (§14 M0 验收反向断言)" do
      done = Channel(String).new
      pool = Agents::Pool.new(max_concurrency: 4) do |job|
        sleep 400.milliseconds if job.session_key.includes?("slow")
        done.send(job.session_key)
      end
      slow_key = Agents.session_key("main", "slow-acc", "email", "peer-a")
      fast_key = Agents.session_key("main", "acc2", "email", "peer-b")
      pool.enqueue(slow_key, "x")
      sleep 50.milliseconds # 确保 slow 先占住 worker
      pool.enqueue(fast_key, "x")
      done.receive.should eq(fast_key) # 慢会话在途时快会话先完成
      done.receive.should eq(slow_key) # 慢会话最终也完成
      pool.shutdown
    end

    it "preserves per-session ordering" do
      order = Channel(Int32).new
      pool = Agents::Pool.new(max_concurrency: 8) do |job|
        order.send(job.payload.to_i)
      end
      key = Agents.session_key("main", "acc1", "email", "peer")
      5.times { |i| pool.enqueue(key, i.to_s) }
      5.times do |i|
        order.receive.should eq(i) # 同会话严格保序
      end
      pool.shutdown
    end

    it "caps global concurrency across sessions" do
      inflight = Atomic(Int32).new(0)
      peak = 0
      peak_mutex = Mutex.new
      pool = Agents::Pool.new(max_concurrency: 2) do |_job|
        current = inflight.add(1) + 1
        peak_mutex.synchronize { peak = current if current > peak }
        sleep 50.milliseconds
        inflight.add(-1)
      end
      3.times do |sess|
        key = Agents.session_key("main", "acc#{sess}", "email", "peer")
        2.times { |i| pool.enqueue(key, i.to_s) }
      end
      wait_for { inflight.get == 0 }.should be_true # 全部 6 个 job 完成
      peak.should be <= 2                           # 全局上限生效（§8.3）
      pool.shutdown
    end

    it "formats session keys with account dimension (B4 修复)" do
      Agents.session_key("main", "acc1", "email", "peer@example.com")
        .should eq("agent:main:acc1:email:peer@example.com")
    end

    it "caches provider instances per agent (A1 实例池)" do
      pool = Providers::Pool.new
      p1 = pool.for_agent("main") { Providers::FakeProvider.new("m1") }
      p2 = pool.for_agent("main") { Providers::FakeProvider.new("m2") }
      p1.should be(p2) # 同 agent 复用同一实例
      pool.for_agent("work") { Providers::FakeProvider.new("m3") }
      pool.size.should eq(2)
      pool.replace("main", Providers::FakeProvider.new("hot")) # 热换入口
      pool.for_agent("main") { raise "should not recreate" }.model.should eq("hot")
    end

    it "resolves provider specs from the compile-time table (A2)" do
      spec = Providers.spec_for("deepseek").should_not be_nil
      spec.base_url.should contain("deepseek")
      Providers.spec_for("nonexistent").should be_nil
    end

    it "completes via openai-compatible HTTP against a fake server" do
      server = HTTP::Server.new do |context|
        context.response.content_type = "application/json"
        context.response.print(%({"choices":[{"message":{"role":"assistant","content":"pong"}}]}))
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      begin
        provider = Providers::HttpProvider.new(
          Providers::Spec.new("openai", "http://127.0.0.1", "openai"),
          "test-model", "sk-x", client_base: "http://127.0.0.1:#{addr.port}"
        )
        completion = provider.complete([Providers::Message.new("user", "ping")])
        completion.ok?.should be_true
        completion.text.should eq("pong")
      ensure
        server.close
      end
    end

    it "turns provider failures into error completions (typed rescue 转值)" do
      provider = Providers::HttpProvider.new(
        Providers::Spec.new("openai", "http://127.0.0.1:1", "openai"), "m", "k", timeout: 100.milliseconds
      )
      completion = provider.complete([Providers::Message.new("user", "hi")])
      completion.ok?.should be_false
      completion.error.should_not be_nil
    end
  end
end
