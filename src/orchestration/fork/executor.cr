# frozen_string_literal: true

require "json"

module Sebas
  module Orchestration
    module Fork
      # fork 分身执行体（M4.1-WP3）：固定快照 → 分身任务登记（WP2 任务树契约）→
      # 并发 fiber 执行（信号量约束）→ Expectations 判定。
      #
      # 快照在**首个成员执行前只读一次**（CodeRabbit）：父会话在成员执行期间
      # 新增 transcript 不再滑动窗口——全部成员看到同一父上下文（§1.2 fork 那一刻）。
      #
      # 并发闸限「同时在跑的分身 turn 数」：默认 3（循 subagent.cr:16 先例），
      # 可配置；成员以独立 fiber 跑，超闸任务在信号量 acquire 处排队（§1.5）。
      #
      # 派发契约（WP2）：create 时 members 即登记**全量声明成员**（pre-register），
      # 派发完置 members_final=1——judge/recover 只处理 final=1 的行，派发未完成
      # 的 expectation 不得落定（CodeRabbit：中途崩溃会把不完整集合判成部分完成）。
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

        # 执行一次 fork：预登记全量成员 → 并发 fiber 跑分身 turn →
        # 成员终态即判（any 首个成功即刻 settle 并停止派发剩余）→
        # deadline 到期停止启动排队成员（已落库 transcript 保留，迟到结果
        # 不覆盖 expired）。返回已派发成员的结果数组（§1.4 回执素材）。
        def run(parent_task_id : String, parent_session_key : String,
                parent_agent_id : String, parent_persona : String, skills_text : String,
                input : SnapshotBuilder::Input) : Array(MemberResult)
          fork_id = "fork:" + ::Random::Secure.hex(4)
          declared = (1..input.count).map { |i| fork_id + ":#{i}" }
          # deadline 在持久化前只算一次：快照读取耗时计入期限（CodeRabbit——
          # 否则慢快照会把启动门槛推后到已持久化期限之外）。
          deadline = ::Time.utc + input.deadline.seconds
          row = @expectations.create(fork_id, parent_task_id, parent_session_key,
            input.mode, declared, deadline)
          # 预登记即声明为「派发中」：judge 对 final=0 跳过（成员任务逐个 create
          # 期间不判，防误报缺失）；派发完成后 mark_dispensed 置回 1 终判。
          @store.expectations_unmark_dispensed(row.id)

          # 固定快照：首成员执行前读一次父 transcripts（§1.2 fork 那一刻的上下文）
          window = input.window || SnapshotBuilder::DEFAULT_WINDOW
          frozen_transcripts = @store.transcripts(parent_session_key).last(window)

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

            # any 已 settle：不再启动排队成员（首个成功即收口，§2.3）
            row = @store.expectation?(fork_id)
            if row.nil? || row.try(&.status) != "open"
              @store.fail_task(task_id, "cancelled: any settled before dispatch")
              next
            end
            # 闸复查：deadline 已到 → 排队成员不再启动（已落库 transcript 保留）
            if ::Time.utc >= deadline
              @store.fail_task(task_id, "cancelled: deadline passed before dispatch")
              next
            end

            messages = SnapshotBuilder.build(frozen_transcripts, parent_persona,
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
            # 成员进终态即判：any 首个成功即刻 settle（后续成员在闸口被拒）
            @expectations.judge(fork_id)
          end
          # 派发完成标记后终判：all/allSettled 在此收口；any 已在成员终态时判过
          @store.expectations_mark_dispensed("join:#{fork_id}")
          @expectations.judge(fork_id)
          results
        end

        private def acquire_slot(&block)
          @semaphore.acquire
          begin
            block.call
          ensure
            @semaphore.release
          end
        end
      end
    end
  end
end
