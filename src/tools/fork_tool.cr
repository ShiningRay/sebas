# frozen_string_literal: true

require "json"

module Sebas
  module Tools
    # 对话流内自然 fork（M4.3-WP2，Q7：fork 是对话一等公民）——
    # ReAct 循环工具面的 fork 触发工具。四重闸（semantics §6）：
    # ①能力衰减：仅父 agent 的 ReAct 面注册（分身 fork 面无此工具），
    #   分身显式声明 fork 被 Capability 白名单校验硬编码剔除列明；
    # ②并发闸：count ≤ Executor::DEFAULT_MAX_CONCURRENT（超限整体拒绝）；
    # ③一级限制：parent_session 固定 = 当前对话会话（ctx.session_key），
    #   分身无此工具即无递归入口（hops=1 最强形式）；
    # ④L3 审批：side_effect=Irreversible → Executor 审批门（未批不执行）。
    # fork → join 回写父会话由 Executor + JoinWriter 承接（对话内自然可见）。
    class ForkTool < Tool
      def initialize(@store : ::Sebas::Platform::Store::Store,
                     @expectations : ::Sebas::Orchestration::Fork::Expectations,
                     @provider_factory : -> Providers::Provider,
                     @approvals : ::Sebas::Orchestration::Approvals::Center?,
                     @main_agent_id : String,
                     @parent_allow : Array(String))
        super("fork", "Fork parallel subagents for a task (join results return to this conversation). Args: task (required), count (1-3), mode (all/any/allSettled), deadline (seconds, default 3600)",
          ReplaySemantics::Effectful, Risk::High, SideEffect::Irreversible)
      end

      def run(args : JSON::Any, ctx : ToolContext) : ToolResult
        task = args["task"]?.try(&.as_s?)
        return ToolResult.error("task is required") if task.nil? || task.empty?
        count = args["count"]?.try(&.as_i?) || 1
        max_concurrent = ::Sebas::Orchestration::Fork::Executor::DEFAULT_MAX_CONCURRENT
        return ToolResult.error("count #{count} exceeds concurrency gate #{max_concurrent}") if count > max_concurrent
        return ToolResult.error("count must be positive") if count <= 0
        mode = args["mode"]?.try(&.as_s?) || "allSettled"
        valid_mode = {"all", "any", "allSettled"}.includes?(mode)
        return ToolResult.error("mode must be all/any/allSettled") unless valid_mode
        deadline = args["deadline"]?.try(&.as_i?) || 3600

        input = ::Sebas::Orchestration::Fork::SnapshotBuilder::Input.new(
          task: task, count: count, window: nil, include: nil,
          tools: nil, role: nil, mode: mode, deadline: deadline
        )
        # parent_session = 当前对话会话（一级限制：分身会话无此工具即无递归
        # 入口）；join 回写经 JoinWriter 落回本对话（对话内自然可见）。
        executor = ::Sebas::Orchestration::Fork::Executor.new(@store, @expectations,
          @provider_factory, approvals: ctx.approvals)
        results = executor.run("dialog-fork", ctx.session_key, @main_agent_id,
          "", "", input, @parent_allow)
        summary = results.map { |res| "#{res.task_id}=#{res.state}" }.join(", ")
        ToolResult.success("forked #{results.size} subagent(s) [#{summary}]; join results will be written back to this conversation")
      rescue ex : ::Exception
        ToolResult.error("fork failed: #{ex.message}")
      end
    end
  end
end
