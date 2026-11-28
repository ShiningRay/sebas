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
      denied_after = [] of String
      # before 恒 deny；after 记录（若实现错误在 deny 路径发出 after，此处必红）
      deny_script = ->(pid : String, hook : String) do
        if hook == "memory.remember.after"
          denied_after << pid
          ::Sebas::Plugins::CallOutcome.success(nil, 0)
        else
          ::Sebas::Plugins::CallOutcome.error("hook_deny", "always_deny: spec", 0)
        end
      end
      denied_dispatcher.subscribe("memory.remember.after", manifest_for("after-spy", "memory.remember.after"))
      denied_dispatcher.dispatch = ObservingDispatch.new("deny-spy", script: deny_script)
      bus = ::Sebas::Plugins::HookBus.new(denied_dispatcher)
      result = driver.write("p", JSON.parse(%({"kind": "memory", "text": "hello", "tags": []})),
        JSON.parse("{}"), hook_bus: bus)
      result["ok"].as_bool.should be_false
      result["error"].as_s.should contain("plugin_deny")
      driver.entries.size.should eq(0) # deny 不落库
      # 否定路径可观察（M3-WP5 review）：装 after 订阅者并断言零派发——
      # 实现错误发出 after 时此处必红；留异步派发完成窗口
      sleep 100.milliseconds
      denied_after.size.should eq(0)
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
      # observe 异步派发（§12.11 不阻塞主流程）：轮询等待完成窗口
      deadline = Time.instant + 2.seconds
      while observed.empty? && Time.instant < deadline
        sleep 10.milliseconds
      end
      observed.size.should eq(1)                      # after 触发（提交成功后）
      entry["tags"].as_a.map(&.as_s).should eq(["x"]) # 条目与 after 同源（M3-WP5 review）
    end

    it "幂等键派生：replay_key/plugin_id/内容指纹共同编码（M3-WP5 review）" do
      params = JSON.parse(%({"kind": "memory", "text": "same", "tags": []}))
      same_task = ::Sebas::Plugins::CapabilityDispatcher::MemoryDriver.idempotency_key("t-1", "p", params)
      replay = ::Sebas::Plugins::CapabilityDispatcher::MemoryDriver.idempotency_key("t-1", "p", params)
      other_task = ::Sebas::Plugins::CapabilityDispatcher::MemoryDriver.idempotency_key("t-2", "p", params)
      other_plugin = ::Sebas::Plugins::CapabilityDispatcher::MemoryDriver.idempotency_key("t-1", "q", params)
      same_task.should_not be_nil
      same_task.should eq(replay)         # 同 task 同内容重放 → 同键（memo 复用）
      other_task.should_not eq(same_task) # 不同 task 写同内容 → 不误并
      other_plugin.should_not eq(same_task)
      ::Sebas::Plugins::CapabilityDispatcher::MemoryDriver.idempotency_key(nil, "p", params).should be_nil # hook 路径不 memo
    end

    it "已提交重放先于 before hook 返回既有 memory_id（换总线后仍守同 key 同 id，M3-WP5 review）" do
      driver = ::Sebas::Plugins::CapabilityDispatcher::MemoryDriver.new
      permissive = ::Sebas::Plugins::HookBus.new(::Sebas::Plugins::HookDispatcher.new)
      params = JSON.parse(%({"kind": "memory", "text": "committed", "tags": []}))
      first = driver.write("p", params, JSON.parse("{}"), hook_bus: permissive, idempotency_key: "task-1")
      first["ok"].as_bool.should be_true
      committed_id = first["memory_id"].as_s

      # 重载后新总线：hook memo 为空且 before 恒 deny——已提交承诺不受影响，
      # 同 key 重放直接返回既有 memory_id，before hook 不再执行
      denying_dispatcher = ::Sebas::Plugins::HookDispatcher.new
      denying_dispatcher.subscribe("memory.remember.before", manifest_for("gatekeeper2", "memory.remember.before"))
      denying_dispatcher.dispatch = DenyOnceDispatch.new
      denying = ::Sebas::Plugins::HookBus.new(denying_dispatcher)
      second = driver.write("p", params, JSON.parse("{}"), hook_bus: denying, idempotency_key: "task-1")
      second["ok"].as_bool.should be_true
      second["memory_id"].as_s.should eq(committed_id)
      driver.entries.size.should eq(1) # 不重复写入
    end

    it "observe 子派发继承链深度：max_depth 跨 fiber 生效（M3-WP5 review）" do
      # 链路：主 fiber gate(before) → before 插件内 hook_bus.observe(after)
      # （模拟 write→observe 的跨 fiber 一跳）→ 子 fiber 继承父深度后计数。
      # 深度预算内 after 可达插件（管道成立）；继承后越限即拒绝。
      run_scenario = ->(max_depth : Int32) do
        dispatcher = ::Sebas::Plugins::HookDispatcher.new
        dispatcher.subscribe("memory.remember.before", manifest_for("deep-before", "memory.remember.before"))
        dispatcher.subscribe("memory.remember.after", manifest_for("deep-after", "memory.remember.after"))
        after_called = false
        bus_ref = nil
        script = ->(_pid : String, hook : String) do
          if hook == "memory.remember.after"
            after_called = true
          else
            bus = bus_ref
            if bus
              bus.observe("memory.remember.after", JSON.parse("{}"),
                JSON.parse(%({"memory_id": "m", "kind": "memory", "tags": []})))
            end
          end
          ::Sebas::Plugins::CallOutcome.success(nil, 0)
        end
        dispatcher.dispatch = ObservingDispatch.new("deep", script: script)
        # 共享预算工厂（turn 级装配口径）：gate 与 observe 子派发同一 Budget
        budget = ::Sebas::Plugins::HookDispatcher::Budget.new(max_calls: 64, max_depth: max_depth, max_total_ms: 10_000)
        bus = ::Sebas::Plugins::HookBus.new(dispatcher, budget_factory: -> { budget })
        bus_ref = bus
        # bus.gate 经共享预算工厂取得同一 Budget 实例（不直传 budget）
        verdict = bus.gate("memory.remember.before", JSON.parse("{}"),
          JSON.parse(%({"entry": {"kind": "memory", "text": "x", "tags": []}})))
        verdict.denied.should be_false
        deadline = Time.instant + 2.seconds
        if max_depth == 1
          sleep 200.milliseconds # 子派发完成窗口后再断言未达
        else
          until after_called || Time.instant >= deadline
            sleep 10.milliseconds
          end
        end
        after_called
      end
      run_scenario.call(4).should be_true  # 深度预算内：子派发可达插件
      run_scenario.call(1).should be_false # 继承深度后越限：after 插件不被调用
    end
  end

  describe "SessionCompactor 接口与协议（M3-WP5，WBS：无生产压缩器）" do
    it "协议：before → 压缩 → after（成功提交后，带计数与摘要元数据）" do
      order = [] of String
      fake_dispatcher = ::Sebas::Plugins::HookDispatcher.new
      fake_dispatcher.subscribe("session.compact.before", manifest_for("cb", "session.compact.before"))
      fake_dispatcher.subscribe("session.compact.after", manifest_for("ca", "session.compact.after"))
      script = ->(_pid : String, hook : String) do
        order << (hook == "session.compact.before" ? "hooked-before" : "hooked-after")
        ::Sebas::Plugins::CallOutcome.success(nil, 0)
      end
      fake_dispatcher.dispatch = ObservingDispatch.new("hooked", script: script)
      bus = ::Sebas::Plugins::HookBus.new(fake_dispatcher)
      compactor = RecordingCompactor.new(order)
      runner = ::Sebas::Sessions::Compaction::CompactionRunner.new(bus)
      result = runner.run(compactor, "sess-1", ["m1", "m2"]) { |result| order << "committed:#{result.summary}" }
      result.summary.should eq("summary-2")
      # observe 异步派发（§12.11 不阻塞主流程）：轮询等四个记录点齐再断言
      deadline = Time.instant + 2.seconds
      until order.size == 4
        break if Time.instant >= deadline
        sleep 10.milliseconds
      end
      order.size.should eq(4)
      # 确定性不变式（异步 observe 下可确序的口径）：
      # ① 压缩先于 commit（同步链）；② commit（摘要提交）先于 after 成功通知
      # ——不得先于落库（M3-WP5 review 核心）。before 观察与 compact 的先后
      # 不再可确序（observe 已异步），只断言其到场。
      compact_idx = order.index("compact").should_not be_nil
      committed_idx = order.index("committed:summary-2").should_not be_nil
      after_idx = order.index("hooked-after").should_not be_nil
      compact_idx.should be < committed_idx
      committed_idx.should be < after_idx
      order.count("hooked-before").should eq(1)
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
      after_seen = [] of String
      after_script = ->(pid : String, hook : String) do
        after_seen << pid if hook == "session.compact.after" # 只记 after；before 仍入 order
        order << "before-observed" unless hook == "session.compact.after"
        ::Sebas::Plugins::CallOutcome.success(nil, 0)
      end
      fake_dispatcher.subscribe("session.compact.after", manifest_for("ca2", "session.compact.after"))
      fake_dispatcher.dispatch = ObservingDispatch.new("hooked", script: after_script)
      expect_raises(::Exception, /compaction failed/) do
        runner.run(boom, "sess-2", ["m1"]) { |_r| raise "commit must not run" }
      end
      # before 观察已异步发出：轮询等其记录点；after 派发从未发起（失败
      # 路径不 spawn），完成窗口后断言零派发（可观察否定路径，M3-WP5 review）
      deadline = Time.instant + 2.seconds
      until order.size == 1
        break if Time.instant >= deadline
        sleep 10.milliseconds
      end
      sleep 100.milliseconds
      after_seen.size.should eq(0) # 只有 before；after 不触发
      order.size.should eq(1)
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
