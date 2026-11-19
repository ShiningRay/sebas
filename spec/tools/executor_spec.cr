require "spec"
require "json"
require "../../src/tools/executor"
require "../../src/channels/registry"
require "../../src/platform/store/store"

# 计数假适配器：记录发送次数与键
class CountingAdapter < ::Sebas::Channels::ChannelAdapter
  getter sends = [] of String
  @mutex = Mutex.new
  property? fail_next : Bool = false

  def initialize
    super("email", "test-acc")
  end

  def start : Nil; end

  def stop : Nil; end

  def send(peer : String, content : String, idempotency_key : String? = nil) : ::Sebas::Channels::SendResult
    @mutex.synchronize do
      return ::Sebas::Channels::SendResult.error("injected failure") if @fail_next
      @sends << "#{peer}:#{content}:#{idempotency_key}"
      ::Sebas::Channels::SendResult.success("msg-#{@sends.size}")
    end
  end

  def send_count : Int32
    @mutex.synchronize { @sends.size }
  end
end

def wait_for(seconds : Time::Span = 5.seconds, &condition : -> Bool) : Bool
  deadline = Time.instant + seconds
  until Time.instant > deadline
    return true if condition.call
    sleep 10.milliseconds
  end
  condition.call
end

def fresh_store : ::Sebas::Platform::Store::Store
  dir = Path[Dir.tempdir, "sebas-tools-spec", Random::Secure.hex(4)]
  ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
end

def ctx_for(store, event_id = "evt-1") : ::Sebas::Tools::ToolContext
  ::Sebas::Tools::ToolContext.new("agent:main:acc1:email:peer", "acc1", event_id, store)
end

module Sebas
  describe "tools registry + executor (M0-WP6)" do
    it "exposes typed replay/risk metadata (A9)" do
      channels = Channels::Registry.new
      registry = Tools.default_registry(channels)
      send_tool = registry.find("message.send").should_not be_nil
      send_tool.replay.should eq(Tools::ReplaySemantics::Effectful)
      send_tool.risk.should eq(Tools::Risk::High)
      registry.find("memory.search").try(&.replay).should eq(Tools::ReplaySemantics::Safe)
      registry.describe.should contain("message.send")
    end

    it "redacts sensitive args in logs (A9 脱敏)" do
      args = JSON.parse(%({"peer": "x@y.z", "password": "s3cret", "api_key": "sk-1"}))
      red = Tools::Registry.redact(args)
      red.should contain("[REDACTED]")
      red.should_not contain("s3cret")
      red.should contain("x@y.z")
    end

    it "sends with derived idempotency key and records the memo" do
      store = fresh_store
      adapter = CountingAdapter.new
      channels = Channels::Registry.new
      channels.register(adapter)
      executor = Tools::Executor.new(Tools.default_registry(channels), channels)
      args = JSON.parse(%({"channel": "email", "peer": "x@y.z", "content": "hello"}))
      result = executor.run("message.send", args, ctx_for(store, "evt-9"))
      result.ok?.should be_true
      adapter.send_count.should eq(1)
      store.memo_get("tool-send:send:test-acc:evt-9").to_s.should contain("done:")
      store.close
    end

    it "does not re-deliver on replay with the same key (§14 M0 验收第 3 条)" do
      store = fresh_store
      adapter = CountingAdapter.new
      channels = Channels::Registry.new
      channels.register(adapter)
      executor = Tools::Executor.new(Tools.default_registry(channels), channels)
      args = JSON.parse(%({"channel": "email", "peer": "x@y.z", "content": "hello", "idempotency_key": "send:acc1:evt-7"}))
      executor.run("message.send", args, ctx_for(store)).ok?.should be_true
      # 崩溃恢复重放：同 requestId 再投递
      result = executor.run("message.send", args, ctx_for(store))
      result.ok?.should be_true
      result.output.should contain("already delivered")
      adapter.send_count.should eq(1) # 重复投递不重发
      store.close
    end

    it "fails closed when a previous send was interrupted mid-flight" do
      store = fresh_store
      adapter = CountingAdapter.new
      channels = Channels::Registry.new
      channels.register(adapter)
      executor = Tools::Executor.new(Tools.default_registry(channels), channels)
      args = JSON.parse(%({"channel": "email", "peer": "x@y.z", "content": "hello", "idempotency_key": "send:acc1:evt-8"}))
      store.memo_put("tool-send:send:acc1:evt-8", "intent") # 模拟崩溃残留
      result = executor.run("message.send", args, ctx_for(store))
      result.ok?.should be_false
      result.error.to_s.should contain("interrupted")
      adapter.send_count.should eq(0) # 状态未知不重发
      store.close
    end

    it "clears the intent memo on failure so retries are allowed" do
      store = fresh_store
      adapter = CountingAdapter.new
      adapter.fail_next = true
      channels = Channels::Registry.new
      channels.register(adapter)
      executor = Tools::Executor.new(Tools.default_registry(channels), channels)
      args = JSON.parse(%({"channel": "email", "peer": "x@y.z", "content": "hello", "idempotency_key": "send:acc1:evt-6"}))
      executor.run("message.send", args, ctx_for(store)).ok?.should be_false
      adapter.fail_next = false
      executor.run("message.send", args, ctx_for(store)).ok?.should be_true
      adapter.send_count.should eq(1)
      store.close
    end

    it "supports memory search/save and session read tools" do
      store = fresh_store
      channels = Channels::Registry.new
      executor = Tools::Executor.new(Tools.default_registry(channels), channels)
      executor.run("memory.save", JSON.parse(%({"key": "pref", "body": "user likes concise replies"})), ctx_for(store)).ok?.should be_true
      result = executor.run("memory.search", JSON.parse(%({"query": "concise"})), ctx_for(store))
      result.ok?.should be_true
      result.output.should contain("pref")
      executor.run("session.read", JSON.parse(%({})), ctx_for(store)).ok?.should be_true
      store.close
    end

    it "turns unknown tools and crashes into error values" do
      store = fresh_store
      channels = Channels::Registry.new
      executor = Tools::Executor.new(Tools.default_registry(channels), channels)
      executor.run("nope.tool", JSON.parse(%({})), ctx_for(store)).error.to_s.should contain("unknown tool")
      result = executor.run("memory.search", JSON.parse(%({})), ctx_for(store))
      result.ok?.should be_false
      store.close
    end
  end
end
