require "json"
require "../platform/store/store"
require "../tools/executor"
require "./dsl/dsl"
require "../log"

# 持久 Task 引擎（M2-WP2，design.md §7.2 效应三明治 + §7.3 幂等三件套）：
# workflow run = Task 树；每个动作一个 phase，phase 尾 checkpoint；
# 崩溃重放单位 = phase：已 checkpoint 的动作经 memo 决策幂等跳过，不重复执行。
# restartLimit 由 store 层防护（连续崩溃 5 次 → failed）。
module Sebas
  module Orchestration
    class Engine
      Log = Sebas::Log.for("sebas.orchestration.engine")

      getter store : ::Sebas::Platform::Store::Store

      def initialize(@store : ::Sebas::Platform::Store::Store,
                     @executor : Tools::Executor, @account_id : String = "engine")
      end

      # 启动一次 workflow run：意图先落库（效应三明治第①步）→ 逐动作执行（第②步）→ 结果落库（第③步）
      # 返回 run task id。幂等：同 trigger_event_id 二次启动不重跑。
      def start(workflow : DSL::Workflow, trigger_event_id : String) : String?
        run_id = "run:#{workflow.id}:#{trigger_event_id}"
        return unless @store.record_intent(run_id, "workflow_run", workflow.id)
        @store.finish_intent(run_id, "dispatched")
        task = @store.create_task(run_id, "run", payload: %({"workflow": "#{workflow.id}"}))
        spawn_run(task.id, workflow, trigger_event_id)
        run_id
      end

      # 同步执行（spec/测试口径）：逐动作推进，phase 尾 checkpoint
      def run_sync(workflow : DSL::Workflow, trigger_event_id : String,
                   ctx_session : String = "agent:main:engine:orchestration") : Tools::ToolResult
        run_id = "run:#{workflow.id}:#{trigger_event_id}"
        unless @store.record_intent(run_id, "workflow_run", workflow.id)
          return Tools::ToolResult.success("already dispatched (intent exists)")
        end
        @store.finish_intent(run_id, "dispatched")
        task = @store.create_task(run_id, "run", payload: %({"workflow": "#{workflow.id}"}))
        execute_phases(task.id, workflow, ctx_session)
      end

      # 崩溃恢复：interrupted 的 run 从最近 checkpoint 续跑（重放单位=phase）
      # 已完成 phase 的动作经 memo 幂等跳过（决策级 memo first-write-wins）
      def resume_interrupted : Int32
        resumed = 0
        @store.recover!.each do |task|
          next unless task.kind == "run"
          workflow_id = task.id.split(":")[1]? || ""
          next if workflow_id.empty?
          @store.resume_task(task.id)
          workflow = workflows[workflow_id]?
          next unless workflow
          @store.checkpoint(task.id, task.phase) # 保持 checkpoint（续跑起点）
          execute_phases(task.id, workflow, "agent:main:engine:orchestration", from_phase: task.phase)
          resumed += 1
        end
        resumed
      end

      # workflow 注册表（M2-WP3 触发器共用；由网关/DSL 装载）
      getter workflows = {} of String => DSL::Workflow

      def register(workflow : DSL::Workflow) : Nil
        @workflows[workflow.id] = workflow
      end

      private def execute_phases(run_id : String, workflow : DSL::Workflow,
                                 ctx_session : String, from_phase : Int32 = 0) : Tools::ToolResult
        workflow.actions.each_with_index do |action, index|
          next if index < from_phase # 重放：跳过已 checkpoint 的 phase（不重复执行）

          # 决策级幂等：动作结果 memo first-write-wins；重放读到已存答案不再执行
          memo_key = "action:#{run_id}:#{action.id}"
          existing = @store.memo_get(memo_key)
          if existing
            @store.checkpoint(run_id, index + 1)
            next
          end

          @store.memo_put(memo_key, "running")
          result = @executor.run(action.tool, ::JSON.parse(action.args),
            Tools::ToolContext.new(ctx_session, @account_id, run_id, @store))

          if result.ok?
            # phase 尾 commit checkpoint + 结果 memo（效应三明治第②③步）
            @store.memo_replace(memo_key, "done:#{result.output[0, 120]}")
            @store.checkpoint(run_id, index + 1)
          else
            # 动作失败：意图 memo 标 failed 允许重试；run 标 failed；intent 保持 dispatched
            @store.memo_replace(memo_key, "failed:#{result.error}")
            @store.fail_task(run_id, "action #{action.id} failed: #{result.error}")
            return Tools::ToolResult.error("run #{run_id} failed at #{action.id}: #{result.error}")
          end
        end
        @store.complete_task(run_id, %({"workflow": "#{workflow.id}", "actions": #{workflow.actions.size}}))
        Tools::ToolResult.success("run #{run_id} completed")
      end
    end
  end
end
