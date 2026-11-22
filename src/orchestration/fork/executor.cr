# frozen_string_literal: true

require "json"

module Sebas
  module Orchestration
    module Fork
      # fork 分身执行体（M4.1-WP3）：快照组装 → 分身任务登记（M4.1-WP2 的
      # 任务树契约）→ 并发信号量约束的 turn 执行 → Expectations 判定。
      #
      # 并发闸限「同时在跑的分身 turn 数」：默认 3（循 subagent.cr:16 先例），
      # 可配置；超闸任务在信号量 acquire 处排队执行，不失控（§1.5）。
      # turn 走 HttpProvider 纯消息接口（providers.cr:58-88）；M4.1 默认只读档
      # 不触发 L3 审批链（§7）。
      class Executor
        DEFAULT_MAX_CONCURRENT = 3

        getter store : ::Sebas::Platform::Store::Store
        getter semaphore : ::Sebas::Agents::Semaphore
        getter max_concurrent : Int32

        def initialize(@store : ::Sebas::Platform::Store::Store,
                       @expectations : Expectations,
                       @provider_factory : -> Providers::Provider,
                       max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT)
          @semaphore = ::Sebas::Agents::Semaphore.new(max_concurrent)
          @max_concurrent = max_concurrent
        end

        record MemberResult,
          task_id : String, session_key : String, state : String,
          conclusion : String?

        # 执行一次 fork：登记 fork_child 任务（树挂父任务）→ 并发约束下逐分身
        # turn → 完成落库 → expectation 判定。返回成员结果数组（§1.4 回执素材）。
        def run(parent_task_id : String, parent_session_key : String,
                parent_agent_id : String, parent_persona : String, skills_text : String,
                input : SnapshotBuilder::Input) : Array(MemberResult)
          fork_id = "fork:" + ::Random::Secure.hex(4)
          expectation = @expectations.create(
            fork_id, parent_task_id, parent_session_key,
            input.mode, [] of String, ::Time.utc + input.deadline.seconds
          )

          results = [] of MemberResult
          input.count.times do |i|
            member_index = i + 1
            task_id = fork_id + ":#{member_index}"
            session_key = ::Sebas::Agents.session_key(
              parent_agent_id, "internal", "fork", "#{fork_id}:#{member_index}"
            )
            @store.create_task(task_id, "fork_child", parent_id: parent_task_id,
              owner_task_id: parent_task_id,
              payload: %({"fork": #{fork_id.inspect}, "member": #{member_index}, "task": #{input.task.inspect}}))
            expectation = append_member(expectation, task_id)

            messages = SnapshotBuilder.build(@store, parent_session_key, parent_persona,
              skills_text, input, member_index)
            acquire_slot do
              provider = @provider_factory.call
              completion = provider.complete(messages)
              if completion.error
                @store.fail_task(task_id, completion.error)
                results << MemberResult.new(task_id, session_key, "failed", nil)
              else
                conclusion = completion.text
                @store.append_transcript(session_key, "user", input.task)
                @store.append_transcript(session_key, "agent", conclusion)
                @store.complete_task(task_id, conclusion)
                results << MemberResult.new(task_id, session_key, "done", conclusion)
              end
            end
          end

          @expectations.judge(fork_id)
          results
        end

        # 并发闸：acquire/release 成对；超闸任务在此排队（acquire 阻塞语义）。
        private def acquire_slot(&block)
          @semaphore.acquire
          begin
            block.call
          ensure
            @semaphore.release
          end
        end

        private def append_member(row : ExpectationRow, task_id : String) : ExpectationRow
          # members 列表在 fork 派发期逐个补全（状态机仍 open）
          @store.expectations_append_member(row.id, task_id)
          @store.expectation(row.fork_id)
        end
      end
    end
  end
end
