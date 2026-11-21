require "log"
require "../../log"
require "./envelope"
require "../../platform/store/store"

# 启动恢复与停机收敛（session-input-scheduling.md §5.2；调度 WP2，issue #4）。
#
# 口径：
# - collecting → 立即按原策略快照 seal（seal_reason: recovery）并入队，不重等 debounce。
# - sealed/queued → 重新入队（registry.recover_dispatch 在 replay 完成后派发，
#   未开始批次不丢且只执行一次：queued→running 受守卫迁移，双派发安全）。
# - running → 按现有 task 恢复规则处理（gateway init 的 store.recover! 先行：
#   running task → interrupted → restartLimit 裁决）；批次工件本体 fail-closed
#   改判 failed（不能证明完成即未完成，不自动重放副作用），消息本体由既有
#   intent 重放路径（replay_unfinished）按原规则续跑，send 幂等键防重复投递。
# - done 批次不重跑（不做任何处理）。
# - steer 行（WP1 落表，语义属 WP4）：本期不动，恢复口径随 WP4 落地。
module Sebas
  module Sessions
    module Scheduling
      module Recovery
        extend self
        Log = Sebas::Log.for("sebas.scheduling.recovery")

        record Summary, sealed : Int32, failed : Int32

        # gateway initialize（store.recover! 之后）调用：收敛遗留批次状态
        def recover_stale(store : ::Sebas::Platform::Store::Store) : Summary
          sealed = 0
          store.collecting_batches.each do |row|
            if store.transition_session_batch(row.batch_id, BatchStatus::Collecting, BatchStatus::Sealed, SealReason::Recovery.to_s)
              store.transition_session_batch(row.batch_id, BatchStatus::Sealed, BatchStatus::Queued)
              sealed += 1
            end
          end
          failed = 0
          store.batches_by_status(BatchStatus::Running).each do |row|
            if store.transition_session_batch(row.batch_id, BatchStatus::Running, BatchStatus::Failed)
              # 成员输入收敛 failed：dispatch 前崩溃的批成员是 batched，dispatch 后是
              # dispatched（副作用不可证完成即未完成，消息本体循 intent 重放规则）
              store.transition_batch_inputs(row.batch_id, InputStatus::Batched, InputStatus::Failed)
              store.transition_batch_inputs(row.batch_id, InputStatus::Dispatched, InputStatus::Failed)
              failed += 1
              Log.warn { "recovery: running batch fail-closed to failed (batch=#{row.batch_id} session=#{row.session_key}); message follows existing intent replay rules" }
            end
          end
          Log.info { "recovery: sealed=#{sealed} failed=#{failed}" } if sealed.positive? || failed.positive?
          Summary.new(sealed, failed)
        end
      end
    end
  end
end
