# frozen_string_literal: true

require "json"
require "digest"

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
        getter last_fork_id : String? = nil
        # 能力衰减裁决（M4.2-WP1）：本次 fork 的生效工具集与剔除清单，
        # 供触发面回执列明（§5.2「可观测，不静默失败」）。
        getter last_grant : Capability::Grant? = nil
        # 成员副作用台账（M4.2-WP2 §2.2）：session_key → ledger；成员执行
        # 期间的 effectful 工具调用入账，run 收尾序列化进成员任务 payload。
        getter member_ledgers : Hash(String, ::Sebas::Tools::EffectsLedger) = Hash(String, ::Sebas::Tools::EffectsLedger).new

        def initialize(@store : ::Sebas::Platform::Store::Store,
                       @expectations : Expectations,
                       @provider_factory : -> Providers::Provider,
                       max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT,
                       @approvals : ::Sebas::Orchestration::Approvals::Center? = nil,
                       @auto_join_write : Bool = true)
          @semaphore = ::Sebas::Agents::Semaphore.new(max_concurrent)
          @max_concurrent = max_concurrent
          # join 回写本体（M4.3-WP2）：join.report 自动回写父会话——此前
          # JoinWriter.write 生产链路零调用（M4.1 依赖外部触发缺口）。
          @join_writer = ::Sebas::Orchestration::Fork::JoinWriter.new(@store)
        end

        # 分身工具上下文（M4.2-WP3 §7）：unattended 固定 true（无人值守 deny
        # 语义）+ approvals 装配引用 + 该成员的副作用台账——分身工具回路
        # （后续 WP）经此构造 ToolContext，L3 未批不执行由 Tools::Executor 门执行。
        def member_context(session_key : String, event_id : String = "fork") : ::Sebas::Tools::ToolContext
          ::Sebas::Tools::ToolContext.new(session_key, "internal", event_id, @store,
            @member_ledgers[session_key]? || ::Sebas::Tools::EffectsLedger.new.tap do |new_ledger|
              @member_ledgers[session_key] = new_ledger
            end, @approvals, true, "deny")
        end

        record MemberResult,
          task_id : String, session_key : String, state : String,
          conclusion : String?

        # 执行一次 fork：预登记全量成员 → 并发 fiber 跑分身 turn →
        # 成员终态即判（any 首个成功即刻 settle 并停止派发剩余）→
        # deadline 到期停止启动排队成员（已落库 transcript 保留，迟到结果
        # 不覆盖 expired）。返回已派发成员的结果数组（§1.4 回执素材）。
        # 返回 {fork_id, members}：fork_id 独立于成员结果（空结果数组 ≠ 无
        # expectation——deadline 在快照期耗尽时成员全取消，报告仍需回写）。
        def run_with_fork_id(parent_task_id : String, parent_session_key : String,
                             parent_agent_id : String, parent_persona : String, skills_text : String,
                             input : SnapshotBuilder::Input) : Tuple(String, Array(MemberResult))
          members = run(parent_task_id, parent_session_key, parent_agent_id,
            parent_persona, skills_text, input)
          {last_fork_id || "", members}
        end

        def run(parent_task_id : String, parent_session_key : String,
                parent_agent_id : String, parent_persona : String, skills_text : String,
                input : SnapshotBuilder::Input, parent_tools_allow : Array(String) = ["*"]) : Array(MemberResult)
          fork_id = "fork:" + ::Random::Secure.hex(4)
          @last_fork_id = fork_id
          # 能力衰减（M4.2-WP1 §5.2）：生效集 = 声明 ∩ 父 allow；未声明走默认
          # 只读档。剔除项随 payload 与 last_grant 回执列明。
          grant = Capability.resolve(input.tools, parent_tools_allow)
          @last_grant = grant
          declared = (1..input.count).map { |i| fork_id + ":#{i}" }
          # deadline 在持久化与一切快照读取前只算一次：指纹快照/transcripts
          # 快照的耗时都计入期限（CodeRabbit——否则慢快照会把启动门槛推后到
          # 已持久化期限之外）。
          deadline = ::Time.utc + input.deadline.seconds
          # 工作区指纹快照（M4.2-WP2 §2.2 L1）：声明 files 即写 memo（declared
          # 标记 + 各文件 sha256；全不存在时 digests 为空——声明状态独立持久化，
          # 不得由 join 侧从 pre_digest 反推）；join 回写时对比——父期间被动过
          # 的文件标 CONFLICT 进父裁决清单，不自动 merge（矩阵通则 2）。
          unless (files = input.files).nil?
            digests = files.compact_map do |path|
              next unless File.file?(path)
              {path, ::Digest::SHA256.hexdigest(File.read(path))}
            end.to_h
            @store.memo_put("fork:#{fork_id}:files", %({"declared": true, "digests": #{digests.to_json}}))
          end
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
              payload: %({"fork": #{fork_id.inspect}, "member": #{member_index}, "task": #{input.task.inspect}, "tools_effective": #{grant.effective.inspect}, "tools_removed": #{grant.removed.inspect}, "effects": []}))
            @member_ledgers[session_key] = ::Sebas::Tools::EffectsLedger.new

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
              skills_text, input, member_index, grant)

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
          flush_member_effects(results)
          # 派发完成标记后终判：all/allSettled 在此收口；any 已在成员终态时判过
          @store.expectations_mark_dispensed("join:#{fork_id}")
          @expectations.judge(fork_id)
          # join.report 自动回写父会话（M4.3-WP2 §6.1 对话一等公民——对话内
          # fork 的 join 结果自然可见；幂等 memo 防重复，四时机语义不变）。
          # auto_join_write=false 供 spec 验证 JoinWriter 本身（手动触发）。
          @join_writer.write(fork_id) if @auto_join_write
          results
        end

        # 副作用清单落库（M4.2-WP2 矩阵通则 1）：ledger 条目合并进成员任务
        # payload 的 effects 数组——join 回写经 build_report 聚合。可重入：
        # run 收尾调用一次；成员工具回路（后续 WP）在每次工具调用后亦可调。
        def flush_member_effects(results : Array(MemberResult)) : Nil
          @member_ledgers.each do |session_key, ledger|
            next if ledger.entries.empty?
            member_task = results.find { |res| res.session_key == session_key }
            next unless member_task
            effects_json = ledger.entries.map(&.to_json_object).to_json
            @store.update_task_effects(member_task.task_id, effects_json)
          end
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
