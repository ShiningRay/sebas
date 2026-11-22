require "json"
require "../platform/store/store"
require "../tools/executor"
require "./ledger"
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
                     @executor : Tools::Executor, @account_id : String = "engine",
                     @ledger : Ledger? = nil)
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

      # 异步启动（gateway 口径）：spawn 逐动作执行
      private def spawn_run(run_id : String, workflow : DSL::Workflow, trigger_event_id : String) : Nil
        spawn(name: "sebas-run:#{run_id}") do
          execute_phases(run_id, workflow, "agent:main:engine:orchestration")
          @store.finish_intent("run:#{workflow.id}:#{trigger_event_id}", "done")
        rescue ex : ::Exception
          Log.error(exception: ex) { "run #{run_id} crashed" }
        end
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

      # fork/join 编排动作处理（M4.1-WP5）：登记 expectation（fork）/ 返回
      # 汇聚状态（join）。分身执行由 ForkManager 执行体在触发面完成。
      # fork 必填字段校验（ Validator 前置：缺字段不被运行时默认值吞掉）。
      private def fork_arg_errors(args : JSON::Any) : Array(String)
        errors = [] of String
        task = args["task"]?.try(&.as_s?)
        count = args["count"]?.try(&.as_i?)
        mode = args["mode"]?.try(&.as_s?)
        deadline = args["deadline"]?.try(&.as_i?)
        errors << "缺 task" if task.nil? || task.empty?
        errors << "缺 count（必填）" if count.nil?
        errors << "count 必须为正整数" if count && count <= 0
        errors << "缺 mode（必填）" if mode.nil?
        errors << "mode 必须为 all/any/allSettled" if mode && !%w[all any allSettled].includes?(mode)
        errors << "缺 deadline（必填）" if deadline.nil?
        errors
      end

      # fork/join 编排动作处理（M4.1-WP5）：fork 经 Executor 实际派发分身并等
      # 终态（JoinWriter 回写父会话在 Executor 内完成）；join 返回汇聚状态。
      # 保存真实 run_id 与 ctx_session（CodeRabbit：父子关系与回写归属必须锚
      # 当前 run 与调用会话，不用固定占位）。
      private def fork_join_action(action : DSL::Action, run_id : String,
                                   ctx_session : String) : Tools::ToolResult
        args = ::JSON.parse(action.args)
        case action.tool
        when "fork"
          validation_errors = fork_arg_errors(args)
          unless validation_errors.empty?
            return Tools::ToolResult.error("fork #{action.id}: #{validation_errors.join("；")}")
          end

          # 校验通过后字段必有值；从 args 重读（nil 已被 fork_arg_errors 拒绝）
          input = ::Sebas::Orchestration::Fork::SnapshotBuilder::Input.new(
            task: args["task"]?.try(&.as_s?) || "", count: args["count"]?.try(&.as_i?) || 0,
            window: nil, include: nil, tools: nil, role: nil,
            mode: args["mode"]?.try(&.as_s?) || "allSettled",
            deadline: args["deadline"]?.try(&.as_i?) || 3600
          )
          # engine 场景分身 provider 工厂未接线（gateway 装配面另卡）：fail-closed
          # 显式报错，不静默跳过分身。
          executor = ::Sebas::Orchestration::Fork::Executor.new(
            @store, ::Sebas::Orchestration::Fork::Expectations.new(@store),
            -> { raise ::Sebas::Platform::Store::StoreError.new("engine 场景 provider 工厂未接线（gateway 装配面另卡）") }
          )
          results = executor.run(run_id, ctx_session, @account_id, "", "", input)
          fork_id = results.first?.try(&.task_id.split(":")[0...2].join(":")).to_s
          ::Sebas::Orchestration::Fork::JoinWriter.new(@store).write(fork_id)
          Tools::ToolResult.success(%({"fork_id": "#{fork_id}", "members": #{results.size}}))
        else # join
          fork_id = args["fork_id"]?.try(&.as_s?) || ""
          row = @store.expectation?(fork_id)
          row ? Tools::ToolResult.success(%({"fork_id": "#{fork_id}", "status": "#{row.status}"})) : Tools::ToolResult.error("join: unknown fork_id #{fork_id}")
        end
      end

      private def execute_phases(run_id : String, workflow : DSL::Workflow,
                                 ctx_session : String, from_phase : Int32 = 0) : Tools::ToolResult
        @ledger.try(&.append(run_id, "run.start", %({"workflow": "#{workflow.id}", "actions": #{workflow.actions.size}})))
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
          @ledger.try(&.append(run_id, "action.start", %({"id": "#{action.id}", "tool": "#{action.tool}"})))
          # fork/join 不走默认工具注册表（不支持这两个原语）——编排处理路径：
          # fork 经 Executor 实际派发分身并等待终态（M4.1-WP3 执行体），join 返回
          # 汇聚状态；生产 agent_turn 不动（Q3）。
          result = if {"fork", "join"}.includes?(action.tool)
                     fork_join_action(action, run_id, ctx_session)
                   else
                     @executor.run(action.tool, ::JSON.parse(action.args),
                       Tools::ToolContext.new(ctx_session, @account_id, run_id, @store))
                   end

          if result.ok?
            # phase 尾 commit checkpoint + 结果 memo（效应三明治第②③步）
            @store.memo_replace(memo_key, "done:#{result.output[0, 120]}")
            @store.checkpoint(run_id, index + 1)
            @ledger.try(&.append(run_id, "action.done", %({"id": "#{action.id}"})))
          else
            # 动作失败：意图 memo 标 failed 允许重试；run 标 failed；intent 保持 dispatched
            @store.memo_replace(memo_key, "failed:#{result.error}")
            @store.fail_task(run_id, "action #{action.id} failed: #{result.error}")
            @ledger.try(&.append(run_id, "action.failed", %({"id": "#{action.id}", "error": #{result.error.inspect}})))
            return Tools::ToolResult.error("run #{run_id} failed at #{action.id}: #{result.error}")
          end
        end
        @store.complete_task(run_id, %({"workflow": "#{workflow.id}", "actions": #{workflow.actions.size}}))
        @ledger.try(&.append(run_id, "run.done", %({"workflow": "#{workflow.id}"})))
        Tools::ToolResult.success("run #{run_id} completed")
      end
    end
  end
end
