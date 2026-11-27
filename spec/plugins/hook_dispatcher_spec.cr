require "spec"
require "file_utils"
require "json"
require "../../src/plugins/hook_dispatcher"
require "../../src/plugins/manifest"
require "../support/plugins_spec_helper"

# 钩子派发语义验收（M3-WP5，#17；design.md §12.11 统一执行规则）：
# 订阅/排序/敏感批准/gate deny fail-closed/transform 替换重校验/observe
# 隔离/预算/memo。outcome 级用例用脚本化 StubDispatch 精确控制；
# deny!/替换语义用临时目录真实插件（解释器可注入，口径同 WP4）。
module Sebas
  module Plugins
    # 脚本化派发桩：按 (plugin_id, hook) 返回预置 outcome，可注入回调观察调用序。
    class StubDispatch < Dispatch
      @@calls = [] of Tuple(String, String)

      def self.calls
        @@calls
      end

      def self.reset
        @@calls.clear
      end

      # script: ->(plugin_id, hook) : CallOutcome
      setter script : (String, String -> CallOutcome)?

      def initialize
        super(Registry.new, Runner.new(["stub-interpreter"]))
      end

      def call_plugin_for_hook(plugin_id : String, hook : String, context : JSON::Any,
                               payload : JSON::Any, idempotency_key : String? = nil) : CallOutcome
        @@calls << {plugin_id, hook}
        script = @script
        return CallOutcome.error("no_script", "stub has no script", 0) unless script
        script.call(plugin_id, hook)
      end
    end

    def self.manifest_with(id : String, hooks : Array(String), sensitive : Bool = false) : Manifest
      caps = sensitive ? ["hooks.sensitive"] : [] of String
      Manifest.parse(%({"schema_version":1,"id":"#{id}","version":"1.0.0","api_version":"1","hooks":#{hooks.inspect},"capabilities":#{caps.inspect}}))
    end

    # 临时目录真实插件：hook 链夹具（deny!/修改替换），解释器口径同 WP4。
    def self.write_plugin(dir : Path, id : String, manifest_extra : String, body : String) : Nil
      plugin_dir = dir / id
      Dir.mkdir_p(plugin_dir)
      caps = manifest_extra.includes?("sensitive") ? %(["hooks.sensitive"]) : %([])
      File.write(plugin_dir / "manifest.json", %({"schema_version":1,"id":"#{id}","version":"1.0.0","api_version":"1","hooks":["memory.remember.before"],"capabilities":#{caps}}))
      File.write(plugin_dir / "plugin.rb", body)
    end

    describe "hook dispatcher（M3-WP5）" do
      before_each { StubDispatch.reset }

      it "订阅：未知钩子拒绝；同插件重复订阅拒绝" do
        d = HookDispatcher.new
        m = manifest_with("p1", ["tool.call.after"])
        expect_raises(Hooks::SchemaError, /unknown hook/) do
          d.subscribe("free.form", m)
        end
        d.subscribe("tool.call.after", m)
        expect_raises(Hooks::SchemaError, /already subscribes/) do
          d.subscribe("tool.call.after", m)
        end
      end

      it "敏感 hook 须 manifest 声明 hooks.sensitive（§12.11 单独批准）" do
        d = HookDispatcher.new
        plain = manifest_with("plain", ["memory.remember.before"])
        expect_raises(Hooks::SchemaError, /hooks\.sensitive/) do
          d.subscribe("memory.remember.before", plain)
        end
        approved = manifest_with("approved", ["memory.remember.before"], sensitive: true)
        d.subscribe("memory.remember.before", approved)
        d.subscribers("memory.remember.before").size.should eq(1)
      end

      it "priority 大者优先，同优先级按插件 ID 稳定排序（§12.11）" do
        d = HookDispatcher.new
        [{"b", 5}, {"a", 5}, {"c", 9}].each do |(id, pri)|
          m = Manifest.parse(%({"schema_version":1,"id":"#{id}","version":"1.0.0","api_version":"1","hooks":["tool.call.after"],"capabilities":["hooks.sensitive"],"hook_priorities":{"tool.call.after":#{pri}}}))
          d.subscribe("tool.call.after", m)
        end
        d.subscribers("tool.call.after").map(&.plugin_id).should eq(["c", "a", "b"])
      end

      it "payload 契约违约：observe 跳过、gate 判 deny（fail-closed）" do
        stub = StubDispatch.new
        stub.script = ->(_pid : String, _hook : String) { CallOutcome.success(nil, 0) }
        d = HookDispatcher.new
        d.dispatch = stub
        m = manifest_with("p", ["message.sent"], sensitive: true)
        d.subscribe("message.sent", m)

        d.observe("message.sent", JSON.parse("{}"), JSON.parse(%({"status": "success"})))
        StubDispatch.calls.size.should eq(0) # 缺必需键：跳过，不派发

        verdict = d.gate("tool.call.before", JSON.parse("{}"),
          JSON.parse(%({"tool_id": "t"}))) # 缺 request_id/session_key/params
        verdict.denied.should be_true
        verdict.code.should eq("invalid_payload")
      end

      it "gate：显式 deny 短路停链；后续处理器不执行" do
        stub = StubDispatch.new
        stub.script = ->(pid : String, _hook : String) do
          if pid == "denier"
            CallOutcome.error("hook_deny", "empty_memory: Memory text must not be empty", 1)
          else
            CallOutcome.success(nil, 0)
          end
        end
        d = HookDispatcher.new
        d.dispatch = stub
        {"denier", "follower"}.each do |id|
          d.subscribe("memory.remember.before", manifest_with(id, ["memory.remember.before"], sensitive: true))
        end
        payload = JSON.parse(%({"entry": {"text": "", "tags": []}}))
        verdict = d.gate("memory.remember.before", JSON.parse("{}"), payload)
        verdict.denied.should be_true
        verdict.reason.should eq("empty_memory: Memory text must not be empty")
        StubDispatch.calls.map(&.first).should eq(["denier"]) # follower 不执行
      end

      it "gate：异常/超时等 error outcome 默认 deny（fail-closed）" do
        stub = StubDispatch.new
        stub.script = ->(_pid : String, _hook : String) do
          CallOutcome.error("timeout", "plugin call exceeded 1500ms and was killed", 1500)
        end
        d = HookDispatcher.new
        d.dispatch = stub
        d.subscribe("agent.turn.before", manifest_with("p", ["agent.turn.before"]))
        verdict = d.gate("agent.turn.before", JSON.parse("{}"),
          JSON.parse(%({"agent_id": "a", "session_key": "s"})))
        verdict.denied.should be_true
        verdict.code.should eq("timeout")
      end

      it "transform：裸返回值替换 payload 并重过 schema；非法替换 deny" do
        stub = StubDispatch.new
        stub.script = ->(_pid : String, _hook : String) do
          CallOutcome.success(JSON.parse(%({"tool_id": "t", "request_id": "r", "session_key": "s", "params": {"q": "rewritten"}})), 1)
        end
        d = HookDispatcher.new
        d.dispatch = stub
        d.subscribe("tool.call.before", manifest_with("rewriter", ["tool.call.before"], sensitive: true))
        payload = JSON.parse(%({"tool_id": "t", "request_id": "r", "session_key": "s", "params": {"q": "original"}}))
        verdict = d.transform("tool.call.before", JSON.parse("{}"), payload)
        verdict.denied.should be_false
        replacement = verdict.payload
        fail("expected replacement payload") if replacement.nil?
        replacement.as_h["params"]["q"].as_s.should eq("rewritten")

        # 替换结果缺键 → 重校验拒绝（invalid_result）
        stub.script = ->(_pid : String, _hook : String) do
          CallOutcome.success(JSON.parse(%({"tool_id": "t"})), 1)
        end
        verdict = d.transform("tool.call.before", JSON.parse("{}"), payload)
        verdict.denied.should be_true
        verdict.code.should eq("invalid_result")
      end

      it "observe：单插件失败被隔离跳过，不影响其余订阅者" do
        stub = StubDispatch.new
        stub.script = ->(pid : String, _hook : String) do
          if pid == "broken"
            CallOutcome.error("plugin_exception", "exploded", 1)
          else
            CallOutcome.success(nil, 1)
          end
        end
        d = HookDispatcher.new
        d.dispatch = stub
        {"broken", "healthy"}.each do |id|
          d.subscribe("task.end", manifest_with(id, ["task.end"]))
        end
        payload = JSON.parse(%({"task_id": "t", "status": "failed"}))
        d.observe("task.end", JSON.parse("{}"), payload) # 不抛
        StubDispatch.calls.map(&.first).should eq(["broken", "healthy"])
      end

      it "kind 不符拒绝：observe 型 hook 不得走 gate/transform" do
        d = HookDispatcher.new
        expect_raises(Hooks::SchemaError, /not a gate/) do
          d.gate("tool.call.after", JSON.parse("{}"), JSON.parse("{}"))
        end
        expect_raises(Hooks::SchemaError, /not a transform/) do
          d.transform("agent.turn.before", JSON.parse("{}"), JSON.parse("{}"))
        end
      end

      it "预算：超限后 observe 跳过剩余订阅者、gate 判 deny（§12.11 fail-closed）" do
        stub = StubDispatch.new
        stub.script = ->(_pid : String, _hook : String) { CallOutcome.success(nil, 0) }
        d = HookDispatcher.new
        d.dispatch = stub
        {"a", "b"}.each { |id| d.subscribe("session.start", manifest_with(id, ["session.start"])) }
        budget = HookDispatcher::Budget.new(max_calls: 1, max_depth: 4, max_total_ms: 10_000)
        d.observe("session.start", JSON.parse("{}"),
          JSON.parse(%({"session_key": "s"})), budget: budget)
        StubDispatch.calls.size.should eq(1) # 第二个订阅者被预算拦下

        verdict = d.gate("agent.turn.before", JSON.parse("{}"),
          JSON.parse(%({"agent_id": "a", "session_key": "s"})),
          budget: HookDispatcher::Budget.new(max_calls: 0, max_depth: 4, max_total_ms: 10_000))
        verdict.denied.should be_true
        verdict.code.should eq("hook_budget_exceeded")
      end

      it "memo：同 idempotency_key 重放复用裁决，不重复执行插件（§12.11）" do
        stub = StubDispatch.new
        count = 0
        stub.script = ->(_pid : String, _hook : String) do
          count += 1
          CallOutcome.success(JSON.parse(%({"verdict": "allow"})), 0)
        end
        d = HookDispatcher.new
        d.dispatch = stub
        d.subscribe("agent.turn.before", manifest_with("p", ["agent.turn.before"]))
        payload = JSON.parse(%({"agent_id": "a", "session_key": "s"}))
        v1 = d.gate("agent.turn.before", JSON.parse("{}"), payload, idempotency_key: "turn-1")
        v2 = d.gate("agent.turn.before", JSON.parse("{}"), payload, idempotency_key: "turn-1")
        v1.denied.should be_false
        v2.should eq(v1)
        count.should eq(1) # 第二次走 memo，不执行插件
      end
    end

    describe "hook dispatcher 真实插件（解释器注入）" do
      interp = PluginSpecSupport.interpreter

      it "deny! DSL：gate 链被判 deny，reason 携带 deny_code" do
        interp2 = interp
        unless interp2
          pending "需要解释器"
          next
        end
        tmp = Path[Dir.tempdir, "sebas-hookspec-#{Random::Secure.hex(4)}"]
        Dir.mkdir_p(tmp)
        begin
          write_plugin(tmp, "denier", "sensitive", <<-RUBY
            on_hook "memory.remember.before" do |payload|
              entry = payload["entry"]
              if entry["text"].to_s.empty?
                deny!("empty_memory", "Memory text must not be empty")
              end
              modify!(payload)
            end
            RUBY
          )
          registry = Registry.new
          report = registry.load_dir(tmp)
          report.errors.each { |e| fail("fixture error: #{e}") }
          dispatch = Dispatch.new(registry, PluginSpecSupport.make_runner(interp2))
          d = HookDispatcher.new
          d.dispatch = dispatch
          report.loaded.each do |id|
            plugin = registry.plugin(id) || fail("plugin #{id} not loaded")
            d.subscribe("memory.remember.before", plugin.manifest)
          end
          verdict = d.gate("memory.remember.before", JSON.parse("{}"),
            JSON.parse(%({"entry": {"text": "", "tags": []}})))
          verdict.denied.should be_true
          verdict.code.should eq("plugin_deny")
          verdict.reason.should eq("empty_memory: Memory text must not be empty")
        ensure
          FileUtils.rm_rf(tmp)
        end
      end

      it "transform 裸返回：memory.remember.before 替换 entry（tags 去重）" do
        interp2 = interp
        unless interp2
          pending "需要解释器"
          next
        end
        tmp = Path[Dir.tempdir, "sebas-hookspec-#{Random::Secure.hex(4)}"]
        Dir.mkdir_p(tmp)
        begin
          write_plugin(tmp, "dedup", "sensitive", <<-RUBY
            on_hook "memory.remember.before" do |payload|
              entry = payload["entry"]
              tags = entry["tags"] || []
              uniq = []
              tags.each do |t|
                uniq.push(t) unless uniq.include?(t)
              end
              entry["tags"] = uniq
              modify!(payload)
            end
            RUBY
          )
          registry = Registry.new
          report = registry.load_dir(tmp)
          report.errors.each { |e| fail("fixture error: #{e}") }
          dispatch = Dispatch.new(registry, PluginSpecSupport.make_runner(interp2))
          d = HookDispatcher.new
          d.dispatch = dispatch
          report.loaded.each do |id|
            plugin = registry.plugin(id) || fail("plugin #{id} not loaded")
            d.subscribe("memory.remember.before", plugin.manifest)
          end
          verdict = d.transform("memory.remember.before", JSON.parse("{}"),
            JSON.parse(%({"entry": {"text": "hello", "tags": ["a", "a", "b"]}})))
          verdict.denied.should be_false
          replacement = verdict.payload
          fail("expected replacement payload") if replacement.nil?
          replacement.as_h["entry"]["tags"].as_a.map(&.as_s).should eq(["a", "b"])
        ensure
          FileUtils.rm_rf(tmp)
        end
      end
    end
  end
end
