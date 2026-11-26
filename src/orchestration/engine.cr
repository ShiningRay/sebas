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
      Log = Sebas::Log.for("orchestration.engine")

      getter store : ::Sebas::Platform::Store::Store

      # provider_factory：DSL fork 分身 provider 装配入口（M4.1-WP5 复审——
      # gateway 构造 Engine 时注入；缺省抛错 fail-closed，DSL fork 明确报
      # 「工厂未接线」而非静默跳过）。
      def initialize(@store : ::Sebas::Platform::Store::Store,
                     @executor : Tools::Executor, @account_id : String = "engine",
                     @ledger : Ledger? = nil,
                     @fork_provider_factory : -> Providers::Provider = -> { raise ::Sebas::Platform::Store::StoreError.new("engine fork provider 工厂未接线（gateway 构造时注入）") })
      end

      # 启动一次 workflow run：意图先落库（效应三明治第①步）→ 逐动作执行（第②步）→ 结果落库（第③步）
      # 返回 run task id。幂等：同 trigger_event_id 二次启动不重跑。
      def start(workflow : DSL::Workflow, trigger_event_id : String,
                batch_id : String? = nil, batch_event_ids : Array(String)? = nil,
                ctx_session : String = "agent:main:engine:orchestration") : String?
        run_id = "run:#{workflow.id}:#{trigger_event_id}"
        return unless @store.record_intent(run_id, "workflow_run", workflow.id)
        @store.finish_intent(run_id, "dispatched")
        # 批量模式（M4.5-WP5）：run payload 记录 batch 与全部 event IDs——
        # batch→run→events 完整审计；ctx_session 持久化（hook 准入会话贯通
        # 执行上下文，恢复续跑同上下文——CodeRabbit bn4j）；逐事件保持精简
        payload = if batch_event_ids
                    {workflow: workflow.id, batch_id: batch_id, event_ids: batch_event_ids, session: ctx_session}.to_json
                  else
                    {workflow: workflow.id, session: ctx_session}.to_json
                  end
        task = @store.create_task(run_id, "run", payload: payload)
        spawn_run(task.id, workflow, trigger_event_id, ctx_session)
        run_id
      end

      # 异步启动（gateway 口径）：spawn 逐动作执行
      private def spawn_run(run_id : String, workflow : DSL::Workflow, trigger_event_id : String,
                            ctx_session : String = "agent:main:engine:orchestration") : Nil
        spawn(name: "sebas-run:#{run_id}") do
          execute_phases(run_id, workflow, ctx_session)
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
          resume_session = begin
            raw = @store.db.query_one?("SELECT payload FROM tasks WHERE id = ?", task.id, as: String)
            parsed = JSON.parse(raw.to_s)
            parsed["session"]?.try(&.as_s?) || "agent:main:engine:orchestration"
          rescue
            "agent:main:engine:orchestration"
          end
          execute_phases(task.id, workflow, resume_session, from_phase: task.phase)
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
      # 派发异常收口：已创建的 fork_child 任务 fail 落终态、expectation 置
      # expired（members_final=0 行 judge 跳过，须直接 transition）。
      private def close_dispersed_fork(executor : ::Sebas::Orchestration::Fork::Executor,
                                       _run_id : String) : Nil
        fork_id = executor.last_fork_id
        return if fork_id.nil?
        row = @store.expectation?(fork_id)
        return if row.nil?
        # 终态保护与计数分离（CodeRabbit）：已终态成员保留；其余成员尝试
        # fail_task 后重读状态，只统计实际处于终态者（fail_task 抛错不递增）。
        Array(String).from_json(row.members).each do |task_id|
          status = @store.task_status?(task_id)
          next if status && %w[done failed cancelled].includes?(status) # 已终态不覆写
          @store.fail_task(task_id, "fork dispatch failed") rescue nil
        end
        settled = Array(String).from_json(row.members).count do |task_id|
          status = @store.task_status?(task_id)
          status && %w[done failed cancelled].includes?(status)
        end
        @store.transition_expectation(row.id, "open", "expired",
          settled_count: settled, result: "dispatch failed")
      rescue
        nil # 收口本身失败不掩盖原始异常
      end

      # snapshot.window 解析：as_i64? 先查 Int32 范围再转换——越界值返回 nil
      # 交由校验错误通路（不在字段校验前抛 OverflowError 绕过 ToolResult 通路）。
      private def parse_window(args : JSON::Any) : Int32?
        args.dig?("snapshot", "window").try(&.as_i64?).try do |value|
          value.in?(Int32::MIN..Int32::MAX) ? value.to_i32 : nil
        end
      end

      # fork 必填字段校验（ Validator 前置：缺字段不被运行时默认值吞掉）。
      # ameba:disable Metrics/CyclomaticComplexity — 字段逐项校验直译卡面规则
      private def fork_arg_errors(args : JSON::Any) : Array(String)
        errors = [] of String
        task = args["task"]?.try(&.as_s?)
        count = args["count"]?.try(&.as_i?)
        mode = args["mode"]?.try(&.as_s?)
        deadline = args["deadline"]?.try(&.as_i?)
        window = parse_window(args)
        errors << "缺 task" if task.nil? || task.empty?
        errors << "缺 count（必填）" if count.nil?
        errors << "count 必须为正整数" if count && count <= 0
        errors << "缺 mode（必填）" if mode.nil?
        errors << "mode 必须为 all/any/allSettled" if mode && !%w[all any allSettled].includes?(mode)
        errors << "缺 deadline（必填）" if deadline.nil?
        if args.dig?("snapshot", "window") && (window.nil? || window < 0)
          errors << "snapshot.window 必须为非负整数（Int32 范围内）"
        end
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

          # 校验通过后字段必有值；从 args 重读（nil 已被 fork_arg_errors 拒绝）。
          # snapshot.window/include 透传 DSL 显式声明（缺失用默认，不覆盖声明）
          input = ::Sebas::Orchestration::Fork::SnapshotBuilder::Input.new(
            task: args["task"]?.try(&.as_s?) || "", count: args["count"]?.try(&.as_i?) || 0,
            window: args.dig?("snapshot", "window").try(&.as_i?),
            include: args.dig?("snapshot", "include").try(&.as_a?)
              .try(&.map { |item| item.as_s? || "" }),
            tools: nil, role: nil,
            mode: args["mode"]?.try(&.as_s?) || "allSettled",
            deadline: args["deadline"]?.try(&.as_i?) || 3600
          )
          executor = ::Sebas::Orchestration::Fork::Executor.new(
            @store, ::Sebas::Orchestration::Fork::Expectations.new(@store), @fork_provider_factory
          )
          # 派发异常收口（CodeRabbit）：任何异常（工厂/provider/存储）发生时，
          # 已创建子任务与 expectation 进入终态（fail_task + expired），动作
          # 失败交给引擎既有失败处理（memo 不留 running，重放重跑动作）。
          begin
            # 分身 agent 段 = 父会话键首段（五段键 agent:...），非 account_id
            # （CodeRabbit：执行与回写须用同一会话键 agent 段）
            parent_agent_id = ctx_session.split(":")[1]? || @account_id
            fork_id, results = executor.run_with_fork_id(run_id, ctx_session, parent_agent_id, "", "", input)
          rescue ex
            close_dispersed_fork(executor, run_id)
            return Tools::ToolResult.error("fork #{action.id} 派发失败：#{ex.message}")
          end
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
