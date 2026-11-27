require "spec"
require "json"
require "../support/plugins_spec_helper"
require "../../src/plugins/capabilities"
require "../../src/sessions/compaction/compactor"

# M3-WP5 第三批验收（#17）：capability driver 双重白名单第二关 + 受控
# memory.backend（memory.remember 双 hook 注入点）+ SessionCompactor 接口
# 与协议（无生产压缩器，WBS 依赖节口径）。
module Sebas
  # 观察型桩派发：记录调用序，script 定制 outcome
  class ObservingDispatch < ::Sebas::Plugins::Dispatch
    property script : (String, String -> ::Sebas::Plugins::CallOutcome)?

    def initialize(@observe_id : String = "hooked", @script : (String, String -> ::Sebas::Plugins::CallOutcome)? = nil)
      super(::Sebas::Plugins::Registry.new, ::Sebas::Plugins::Runner.new(["stub"]))
    end

    def call_plugin_for_hook(plugin_id : String, hook : String, context : JSON::Any,
                             payload : JSON::Any, idempotency_key : String? = nil) : ::Sebas::Plugins::CallOutcome
      script = @script
      return ::Sebas::Plugins::CallOutcome.error("no_script", "stub", 0) unless script
      script.call(@observe_id, hook)
    end
  end

  # 拒绝型桩派发：一切 hook 处理器均 deny
  class DenyOnceDispatch < ::Sebas::Plugins::Dispatch
    def initialize
      super(::Sebas::Plugins::Registry.new, ::Sebas::Plugins::Runner.new(["stub"]))
    end

    def call_plugin_for_hook(plugin_id : String, hook : String, context : JSON::Any,
                             payload : JSON::Any, idempotency_key : String? = nil) : ::Sebas::Plugins::CallOutcome
      ::Sebas::Plugins::CallOutcome.error("hook_deny", "always_deny: spec", 0)
    end
  end

  private def self.manifest_for(id : String, hook : String) : ::Sebas::Plugins::Manifest
    ::Sebas::Plugins::Manifest.parse(%({"schema_version":1,"id":"#{id}","version":"1.0.0","api_version":"1","hooks":["#{hook}"],"capabilities":["hooks.sensitive"]}))
  end

  describe "capability dispatcher + memory driver（M3-WP5）" do
    it "未登记 driver 的 capability 拒绝（fail-closed，双重白名单第二关）" do
      caps = ::Sebas::Plugins::CapabilityDispatcher.new
      expect_raises(::Sebas::Plugins::CapabilityDispatcher::CapabilityError, /no driver registered/) do
        caps.dispatch("p", "unregistered.cap", JSON.parse("{}"), JSON.parse("{}"))
      end
    end

    it "memory_driver.write：写前 gate deny → 不落库不触发 after" do
      driver = ::Sebas::Plugins::CapabilityDispatcher::MemoryDriver.new
      denied_dispatcher = ::Sebas::Plugins::HookDispatcher.new
      denied_dispatcher.subscribe("memory.remember.before", manifest_for("gatekeeper", "memory.remember.before"))
      denied_dispatcher.dispatch = DenyOnceDispatch.new
      bus = ::Sebas::Plugins::HookBus.new(denied_dispatcher)
      result = driver.write("p", JSON.parse(%({"kind": "memory", "text": "hello", "tags": []})),
        JSON.parse("{}"), hook_bus: bus)
      result["ok"].as_bool.should be_false
      result["error"].as_s.should contain("plugin_deny")
      driver.entries.size.should eq(0) # deny 不落库
    end

    it "memory_driver.write：成功路径落库并触发 memory.remember.after" do
      driver = ::Sebas::Plugins::CapabilityDispatcher::MemoryDriver.new
      observing = ::Sebas::Plugins::HookDispatcher.new
      observing.subscribe("memory.remember.after", manifest_for("observer", "memory.remember.after"))
      observed = [] of String
      observing_script = ->(pid : String, _hook : String) do
        observed << pid
        ::Sebas::Plugins::CallOutcome.success(nil, 0)
      end
      observing.dispatch = ObservingDispatch.new("after-observed", script: observing_script)
      bus = ::Sebas::Plugins::HookBus.new(observing)
      result = driver.write("p", JSON.parse(%({"kind": "fact", "text": "sebas rocks", "tags": ["x"]})),
        JSON.parse("{}"), hook_bus: bus)
      result["ok"].as_bool.should be_true
      driver.entries.size.should eq(1)
      entry = driver.entries.values.first
      entry["kind"].as_s.should eq("fact")
      entry["text"].as_s.should eq("sebas rocks")
      observed.size.should eq(1) # after 触发（提交成功后）
    end
  end

  describe "SessionCompactor 接口与协议（M3-WP5，WBS：无生产压缩器）" do
    it "协议：before → 压缩 → after（成功提交后，带计数与摘要元数据）" do
      order = [] of String
      fake_dispatcher = ::Sebas::Plugins::HookDispatcher.new
      fake_dispatcher.subscribe("session.compact.before", manifest_for("cb", "session.compact.before"))
      fake_dispatcher.subscribe("session.compact.after", manifest_for("ca", "session.compact.after"))
      script = ->(_pid : String, _hook : String) do
        order << "hooked"
        ::Sebas::Plugins::CallOutcome.success(nil, 0)
      end
      fake_dispatcher.dispatch = ObservingDispatch.new("hooked", script: script)
      bus = ::Sebas::Plugins::HookBus.new(fake_dispatcher)
      compactor = RecordingCompactor.new(order)
      runner = ::Sebas::Sessions::Compaction::CompactionRunner.new(bus)
      result = runner.run(compactor, "sess-1", ["m1", "m2"])
      result.summary.should eq("summary-2")
      # before 观察先于压缩执行，after 观察在成功提交后（observe_id 相同，以序判定）
      order.should eq(["hooked", "compact", "hooked"])
    end

    it "压缩失败：不触发 compact.after（§12.11 失败/取消不触发 after）" do
      order = [] of String
      fake_dispatcher = ::Sebas::Plugins::HookDispatcher.new
      fake_dispatcher.subscribe("session.compact.before", manifest_for("cb", "session.compact.before"))
      script = ->(_pid : String, _hook : String) do
        order << "before-observed"
        ::Sebas::Plugins::CallOutcome.success(nil, 0)
      end
      fake_dispatcher.dispatch = ObservingDispatch.new("hooked", script: script)
      bus = ::Sebas::Plugins::HookBus.new(fake_dispatcher)
      boom = FailingCompactor.new
      runner = ::Sebas::Sessions::Compaction::CompactionRunner.new(bus)
      expect_raises(::Exception, /compaction failed/) do
        runner.run(boom, "sess-2", ["m1"])
      end
      order.size.should eq(1) # 只有 before；after 不触发
    end
  end
end

private class RecordingCompactor < ::Sebas::Sessions::Compaction::SessionCompactor
  def initialize(@order : Array(String))
  end

  def compact(session_key : String, transcript : Array(String)) : ::Sebas::Sessions::Compaction::CompactionResult
    @order << "compact"
    ::Sebas::Sessions::Compaction::CompactionResult.new("summary-#{transcript.size}", 7, transcript.size)
  end
end

private class FailingCompactor < ::Sebas::Sessions::Compaction::SessionCompactor
  def compact(session_key : String, transcript : Array(String)) : ::Sebas::Sessions::Compaction::CompactionResult
    raise ::Exception.new("compaction failed")
  end
end
