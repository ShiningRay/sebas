require "log"
require "../../log"
require "./envelope"
require "../../platform/store/store"

# 启动恢复与停机收敛（session-input-scheduling.md §5.2；调度 WP2，issue #4）。
#
# 口径：
# - collecting → 立即按原策略快照 seal（seal_reason: recovery）并入队，不重新等待完整 debounce；
#   空批（无成员输入的孤儿批）直接 fail-closed，不入队不派发。
# - sealed/queued → 重新入队（registry.recover_dispatch 在 replay 完成后派发，
#   未开始批次不丢且只执行一次：queued→running 受守卫迁移，双派发安全）；空批 fail-closed。
# - running → 按 intent 实测状态三向收敛（批次+成员同一事务，见 store.settle_batch）：
#   ① 成员 intent 全部 done：turn 已完成、回调丢失 → 批次收敛 done（不重跑）；
#   ② 存在成员 intent 为 nil/pending：turn 未启动（intent 落库先于 turn）→ 批次回退
#      queued 重派（消息不丢：无 intent 即无副作用）；
#   ③ 其余（intent dispatched）：turn 可能已启动 → fail-closed 改判 failed（不自动重放
#      副作用），消息本体循既有 intent 重放规则（replay_unfinished）续跑，send 幂等键防重复投递。
# - done 批次不重跑（不做任何处理）。
# - steer 行（WP1 落表，语义属 WP4）：本期不动，恢复口径随 WP4 落地。
module Sebas
  module Sessions
    module Scheduling
      module Recovery
        extend self
        Log = Sebas::Log.for("scheduling.recovery")

        record Summary, sealed : Int32, requeued : Int32, failed : Int32, settled : Int32

        # gateway initialize（store.recover! 之后）调用：收敛遗留批次状态
        def recover_stale(store : ::Sebas::Platform::Store::Store) : Summary
          sealed = 0
          requeued = 0
          failed = 0
          settled = 0

          store.collecting_batches.each do |row|
            if store.batch_inputs(row.batch_id).empty?
              failed += settle(store, row.batch_id, BatchStatus::Collecting, BatchStatus::Failed, fail_moves)
            else
              if store.transition_session_batch(row.batch_id, BatchStatus::Collecting, BatchStatus::Sealed, SealReason::Recovery.to_s) &&
                 store.transition_session_batch(row.batch_id, BatchStatus::Sealed, BatchStatus::Queued)
                sealed += 1
              end
            end
          end

          store.batches_by_status(BatchStatus::Running).each do |row|
            case classify_running(store, row.batch_id)
            when RunningVerdict::Empty
              failed += settle(store, row.batch_id, BatchStatus::Running, BatchStatus::Failed, fail_moves)
            when RunningVerdict::Completed
              settled += settle(store, row.batch_id, BatchStatus::Running, BatchStatus::Done,
                member_moves([InputStatus::Batched, InputStatus::Dispatched], InputStatus::Done))
              Log.info { "recovery: running batch settled done (work completed, callback lost) (batch=#{row.batch_id})" }
            when RunningVerdict::NotStarted
              requeued += settle(store, row.batch_id, BatchStatus::Running, BatchStatus::Queued,
                member_moves([InputStatus::Batched, InputStatus::Dispatched], InputStatus::Batched))
              Log.info { "recovery: running batch requeued (turn never started) (batch=#{row.batch_id} session=#{row.session_key})" }
            else
              failed += settle(store, row.batch_id, BatchStatus::Running, BatchStatus::Failed,
                member_moves([InputStatus::Batched, InputStatus::Dispatched], InputStatus::Failed))
              Log.warn { "recovery: running batch fail-closed to failed (batch=#{row.batch_id} session=#{row.session_key}); message follows existing intent replay rules" }
            end
          end

          if sealed.positive? || requeued.positive? || failed.positive? || settled.positive?
            Log.info { "recovery: sealed=#{sealed} requeued=#{requeued} settled=#{settled} failed=#{failed}" }
          end
          Summary.new(sealed, requeued, failed, settled)
        end

        # running 批次的四向分类：empty / completed / not_started / started
        private enum RunningVerdict
          Empty
          Completed
          NotStarted
          Started
        end

        private def classify_running(store : ::Sebas::Platform::Store::Store, batch_id : String) : RunningVerdict
          inputs = store.batch_inputs(batch_id)
          return RunningVerdict::Empty if inputs.empty?
          states = inputs.map { |input| store.intent_status(input.event_id) }
          return RunningVerdict::Completed if states.all? { |state| state == "done" }
          return RunningVerdict::NotStarted if states.all? { |state| state.nil? || state == "pending" }
          RunningVerdict::Started
        end

        # 受守卫收敛 + 计数（守卫失败返回 0，不计入 summary）
        private def settle(store : ::Sebas::Platform::Store::Store, batch_id : String,
                           from : BatchStatus, to : BatchStatus,
                           moves : Array(::Sebas::Platform::Store::Store::MemberMove)) : Int32
          store.settle_batch(batch_id, from, to, moves) ? 1 : 0
        end

        private def member_moves(from : Array(InputStatus), to : InputStatus) : Array(::Sebas::Platform::Store::Store::MemberMove)
          from.map { |state| ::Sebas::Platform::Store::Store::MemberMove.new(state, to, nil) }
        end

        private def fail_moves : Array(::Sebas::Platform::Store::Store::MemberMove)
          [] of ::Sebas::Platform::Store::Store::MemberMove
        end
      end
    end
  end
end
