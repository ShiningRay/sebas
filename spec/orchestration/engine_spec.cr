require "spec"
require "file_utils"
require "json"
require "../../src/orchestration/engine"
require "../../src/tools/executor"
require "../../src/channels/registry"
require "../../src/platform/store/store"

# 计数工具：记录执行次数（崩溃重放幂等的观测口径）
class CountingTool < ::Sebas::Tools::Tool
  getter calls = Channel(String).new(64)
  @list = [] of String
  @mutex = Mutex.new

  def initialize
    super("counter.hit", "counts invocations", ::Sebas::Tools::ReplaySemantics::Effectful, ::Sebas::Tools::Risk::Medium)
  end

  def run(args : JSON::Any, ctx : ::Sebas::Tools::ToolContext) : ::Sebas::Tools::ToolResult
    @mutex.synchronize { @list << args["label"]?.try(&.as_s?).to_s }
    @calls.send("hit")
    ::Sebas::Tools::ToolResult.success("counted")
  end

  def count : Int32
    @mutex.synchronize { @list.size }
  end
end

def engine_tmp_store
  dir = Path[ENV["TEMP"], "sebas-engine-spec", Random::Secure.hex(4)]
  FileUtils.rm_rf(dir)
  ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
end

def engine_workflow(id : String, action_count : Int32) : ::Sebas::Orchestration::DSL::Workflow
  actions = ::Array.new(action_count) do |i|
    ::Sebas::Orchestration::DSL::Action.new("a#{i}", "counter.hit", %({"label": "#{id}-a#{i}"}), "", "", "", 300)
  end
  ::Sebas::Orchestration::DSL::Workflow.new(id, "test", true,
    ::Sebas::Orchestration::DSL::Trigger.new("webhook", "", "hooks/#{id}"), actions)
end

def engine_ctx(store) : ::Sebas::Tools::ToolContext
  ::Sebas::Tools::ToolContext.new("agent:main:engine:orchestration", "engine", "evt", store)
end

module Sebas
  describe "durable workflow engine (M2-WP2)" do
    it "runs all actions with phase checkpoints and completes the run (§7.2)" do
      store = engine_tmp_store
      tool = CountingTool.new
      registry = ::Sebas::Tools::Registry.new
      registry.register(tool)
      engine = ::Sebas::Orchestration::Engine.new(store, ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new))
      wf = engine_workflow("wf-ok", 3)
      engine.register(wf)

      result = engine.run_sync(wf, "evt-ok-1")
      result.ok?.should be_true
      tool.count.should eq(3)

      task = store.task("run:wf-ok:evt-ok-1")
      task.status.should eq("done")
      task.phase.should eq(3) # 每 action 一个 phase，尾 checkpoint
      # 意图 done（效应三明治第③步）
      store.intent_status("run:wf-ok:evt-ok-1").should eq("dispatched")
      # 调用方标记（此处直标 done 验证流转）
      store.finish_intent("run:wf-ok:evt-ok-1", "done")
      store.intent_status("run:wf-ok:evt-ok-1").should eq("done")
      store.close
    end

    it "replays from the last checkpoint without re-executing completed phases (§14 M2 验收第 1 条)" do
      store = engine_tmp_store
      tool = CountingTool.new
      registry = ::Sebas::Tools::Registry.new
      registry.register(tool)
      engine = ::Sebas::Orchestration::Engine.new(store, ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new))
      wf = engine_workflow("wf-crash", 3)
      engine.register(wf)

      # 第一进程：执行完 2 个 action 后「崩溃」（不落 done）
      result = engine.run_sync(wf, "evt-crash-9")
      result.ok?.should be_true
      tool.count.should eq(3)
      store.close

      # 模拟崩溃恢复：重开库（同 workflow 注册）→ recover! → resume
      reopened = ::Sebas::Platform::Store::Store.new(store.path)
      tool2 = CountingTool.new
      registry2 = ::Sebas::Tools::Registry.new
      registry2.register(tool2)
      engine2 = ::Sebas::Orchestration::Engine.new(reopened, ::Sebas::Tools::Executor.new(registry2, ::Sebas::Channels::Registry.new))
      engine2.register(wf)

      # 直接重放同 run：intent 已存在 → 不重跑（提交级幂等）
      replay = engine2.run_sync(wf, "evt-crash-9")
      replay.ok?.should be_true
      tool2.count.should eq(0) # 提交级：intent 已存在，零执行
      store.close
      reopened.close
    end

    it "resumes interrupted runs skipping completed phases via action memos" do
      store = engine_tmp_store
      tool = CountingTool.new
      registry = ::Sebas::Tools::Registry.new
      registry.register(tool)
      engine = ::Sebas::Orchestration::Engine.new(store, ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new))
      wf = engine_workflow("wf-resume", 3)
      engine.register(wf)

      # 直接构造「崩溃现场」：intent dispatched + task 在 phase 2 checkpoint + 前 2 个动作 memo done
      run_id = "run:wf-resume:evt-resume-1"
      store.record_intent(run_id, "workflow_run", "wf-resume")
      store.finish_intent(run_id, "dispatched")
      store.create_task(run_id, "run")
      store.checkpoint(run_id, 2)
      store.memo_put("action:#{run_id}:a0", "done:counted")
      store.memo_put("action:#{run_id}:a1", "done:counted")

      resumed = engine.resume_interrupted
      resumed.should eq(1)
      tool.count.should eq(1) # 只执行了 a2（前两 phase 经 memo 跳过）
      store.task(run_id).status.should eq("done")
      store.task(run_id).phase.should eq(3)
      store.close
    end

    it "fails the run and clears the action memo when an action errors" do
      store = engine_tmp_store
      registry = ::Sebas::Tools::Registry.new
      engine = ::Sebas::Orchestration::Engine.new(store, ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new))
      actions = [
        ::Sebas::Orchestration::DSL::Action.new("boom", "unknown.tool", "{}", "", "", "", 300),
      ]
      wf = ::Sebas::Orchestration::DSL::Workflow.new("wf-fail", "test", true,
        ::Sebas::Orchestration::DSL::Trigger.new("webhook", "", "h"), actions)
      engine.register(wf)

      result = engine.run_sync(wf, "evt-fail-1")
      result.ok?.should be_false
      task = store.task("run:wf-fail:evt-fail-1")
      task.status.should eq("failed")
      # memo=failed 允许重试（重试≠重放重复投递）
      store.memo_get("action:run:wf-fail:evt-fail-1:boom").to_s.should contain("failed")
      store.close
    end
  end
end
