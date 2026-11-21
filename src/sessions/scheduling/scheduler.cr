require "log"
require "../../log"
require "./envelope"
require "../../platform/store/store"

# 会话调度权威（session-input-scheduling.md §4/§7；调度 WP2，issue #4）：
# 每会话一个 SessionScheduler，持久批次队列（session_batches 表）为唯一权威；
# admission（去重+原文+入批，同一 SQLite 事务）成功才算接受（契约 §4.2）。
#
# queue 模式（WP2 唯一模式）：每条消息一个独立批次，admit 后立即 seal（flush）
# 并入队；debounce 聚合属 WP3，steer 属 WP4，均不在此实现。
#
# 调度权威上移（契约 §7）：本层决定「何时跑哪一批」；Pool 仅保留跨会话 worker
# 与全局并发闸——每会话同时在途批次 ≤1（@running_batch 守卫 + queued→running
# 受守卫迁移双保险），dispatch 只投递 head，Pool 会话队列中永远 ≤1 个 job，
# 不产生双队列竞争。崩溃恢复语义见 recovery.cr。
module Sebas
  module Sessions
    module Scheduling
      # 每会话调度器：批次状态机 + 有界容量 + 串行派发
      class SessionScheduler
        Log = Sebas::Log.for("sebas.scheduling.scheduler")

        getter session_key : String

        # dispatch 回调：session_key + 批次派发 payload（JSON），由装配方投递给执行体。
        # 返回后批次即在途（queued→running 已迁移）；执行完成必须回调 batch_done。
        alias DispatchFn = String, String -> Nil

        @mutex = Mutex.new
        @running_batch : String? = nil
        @stopping = false
        @metrics : Hash(String, Int64)

        def initialize(@session_key : String, @store : ::Sebas::Platform::Store::Store, @dispatch : DispatchFn)
          @metrics = {
            "admitted"          => 0_i64,
            "duplicate"         => 0_i64,
            "rejected_capacity" => 0_i64,
            "dispatched"        => 0_i64,
            "completed"         => 0_i64,
          } of String => Int64
        end

        # ---- 可观测计数（契约 §6 指标面；IPC 暴露属后续 WP）----
        getter metrics : Hash(String, Int64)

        # ---- admission（契约 §4.2：事务成功才接受；容量超限明确拒绝并计数）----
        #
        # 返回回执：accepted（含排队位）/ duplicate（同 event_id 幂等，不占容量）/
        # rejected（容量超限，可重试——积压下降后重投）。
        def admit(env : InputEnvelope) : AdmissionReceipt
          @mutex.synchronize do
            snapshot = env.policy_snapshot

            # 去重最前置：duplicate 不占容量、不建批（重投已排队事件得 duplicate 而非 rejected）
            if @store.session_input?(env.event_id)
              bump("duplicate")
              Log.debug { "admission duplicate (session=#{@session_key} event=#{env.event_id})" }
              return AdmissionReceipt.new(env.event_id, "", "duplicate", nil)
            end

            load = @store.pending_load(@session_key)
            incoming_bytes = env.payload.bytesize.to_i64

            # 单条自身超批字节预算：明确拒绝（契约 §4.3 字节预算 admission）
            if incoming_bytes > snapshot.max_bytes
              bump("rejected_capacity")
              Log.warn { "admission rejected: input exceeds batch max_bytes (session=#{@session_key} event=#{env.event_id} bytes=#{incoming_bytes} limit=#{snapshot.max_bytes})" }
              return AdmissionReceipt.new(env.event_id, "", "rejected", nil)
            end

            # 会话积压容量（queue.max_pending_batches / queue.max_pending_bytes）
            if load.batches + 1 > snapshot.max_pending_batches || load.bytes + incoming_bytes > snapshot.max_pending_bytes
              bump("rejected_capacity")
              Log.warn { "admission rejected: session backlog at capacity (session=#{@session_key} event=#{env.event_id} pending_batches=#{load.batches}/#{snapshot.max_pending_batches} pending_bytes=#{load.bytes}/#{snapshot.max_pending_bytes})" }
              return AdmissionReceipt.new(env.event_id, "", "rejected", nil)
            end

            seq = @store.next_session_seq(@session_key)
            batch = Batch.new(
              batch_id: ::Sebas::Sessions::Scheduling.batch_id_for(@session_key, seq), session_key: @session_key,
              status: BatchStatus::Collecting, policy_snapshot: snapshot,
              first_seq: seq, last_seq: seq,
              created_at: ::Time.utc.to_rfc3339, sealed_at: nil, seal_reason: nil
            )
            env = finalize_env(env, seq)
            # 批次行 + 首个输入同一事务：崩溃不留孤儿空批（batch_id 序号不被占用）
            unless @store.admit_new_batch(batch, env, 0)
              # 主键守卫兜底（同 session 已互斥，理论不可达）：事务已回滚，零残留
              bump("duplicate")
              Log.debug { "admission duplicate via pk guard (session=#{@session_key} event=#{env.event_id})" }
              return AdmissionReceipt.new(env.event_id, batch.batch_id, "duplicate", nil)
            end

            # queue 模式：每消息独立批次，admit 成功后立即 seal（flush）并入队
            seal_and_queue(batch.batch_id, SealReason::Flush)
            # 空闲即派发；回执排队位 = 本批之前的 pending 批数（自身被派发则为 0）
            dispatched = dispatch_locked
            position = if dispatched == batch.batch_id
                         0
                       elsif dispatched
                         (load.batches - 1).to_i32 # 本批未派发但队首被他批派发：少一个 pending
                       else
                         load.batches.to_i32 # 会话忙：本批排在全部 pending 之后
                       end
            bump("admitted")
            AdmissionReceipt.new(env.event_id, batch.batch_id, "accepted", position)
          end
        end

        # 批次执行完成回调（执行体在成员 turn 全部落库后调用）：
        # 失败成员按 event_id 精确迁移 failed，其余成员 done（不残留 dispatched）；
        # 批次随之 done/failed（同一事务，陈旧回调整组回滚）。随后派发下一批。
        def batch_done(batch_id : String, failed_event_ids : Array(String) = [] of String) : Nil
          @mutex.synchronize do
            return unless @running_batch == batch_id
            @running_batch = nil
            batch_to = failed_event_ids.empty? ? BatchStatus::Done : BatchStatus::Failed
            moves = if failed_event_ids.empty?
                      [::Sebas::Platform::Store::Store::MemberMove.new(InputStatus::Dispatched, InputStatus::Done, nil)]
                    else
                      [::Sebas::Platform::Store::Store::MemberMove.new(InputStatus::Dispatched, InputStatus::Failed, failed_event_ids),
                       ::Sebas::Platform::Store::Store::MemberMove.new(InputStatus::Dispatched, InputStatus::Done, nil)]
                    end
            unless @store.settle_batch(batch_id, BatchStatus::Running, batch_to, moves)
              Log.warn { "stale completion callback ignored (session=#{@session_key} batch=#{batch_id})" }
            end
            bump("completed")
            dispatch_locked
          end
        end

        # 执行体崩溃回调（run_batch_job rescue 路径）：批次 fail-closed 改判 failed；
        # 成员输入保持 dispatched——副作用不可证完成即未完成，消息本体循既有 intent
        # 重放规则续跑（§5.2，send 幂等键防重复投递）
        def batch_crashed(batch_id : String) : Nil
          @mutex.synchronize do
            return unless @running_batch == batch_id
            @running_batch = nil
            @store.settle_batch(batch_id, BatchStatus::Running, BatchStatus::Failed,
              [] of ::Sebas::Platform::Store::Store::MemberMove)
            bump("completed")
            dispatch_locked
          end
        end

        # 启动重派入口（recovery.cr 调用）：仅空闲时派发 head（受 @running_batch 守卫）
        def dispatch_if_idle : Nil
          @mutex.synchronize { dispatch_locked }
        end

        # 停机：置停止旗（在途批收敛后不再派发下一批，pending 批留待启动恢复 §5.2）；
        # collecting 批保守封存（queue 模式常态无 collecting，仅崩溃残留可能存在）。
        def shutdown : Nil
          @mutex.synchronize do
            @stopping = true
            @store.collecting_batches(@session_key).each do |row|
              seal_and_queue(row.batch_id, SealReason::Shutdown)
            end
          end
        end

        # ---- 内部（调用方须持 @mutex）----

        # seal + 入队（受守卫迁移，竞态由状态守卫兜底）
        private def seal_and_queue(batch_id : String, reason : SealReason) : Nil
          @store.transition_session_batch(batch_id, BatchStatus::Collecting, BatchStatus::Sealed, reason.to_s)
          @store.transition_session_batch(batch_id, BatchStatus::Sealed, BatchStatus::Queued)
        end

        # 空闲则派发 head：返回被派发批次 id；nil = 会话忙 / 停止中 / 无待发批 /
        # head 竞态改判 / 派发交接失败（已回退重试态）
        private def dispatch_locked : String?
          return if @running_batch || @stopping
          head = @store.pending_batches(@session_key).first?
          return unless head
          batch_id = head.batch_id
          # 恢复残留的 sealed 先入队（契约 §5.2：sealed/queued 重新入队）
          @store.transition_session_batch(batch_id, BatchStatus::Sealed, BatchStatus::Queued)
          @store.transition_batch_inputs(batch_id, InputStatus::Batched, InputStatus::Dispatched)
          return unless @store.transition_session_batch(batch_id, BatchStatus::Queued, BatchStatus::Running)
          @running_batch = batch_id
          bump("dispatched")
          begin
            @dispatch.call(@session_key, dispatch_payload(batch_id))
          rescue ex
            # 交接失败（如 pool 已关）：批次回退 queued 保持可重试，清在途标记
            Log.error(exception: ex) { "dispatch handoff failed, batch requeued (session=#{@session_key} batch=#{batch_id})" }
            @running_batch = nil
            @store.settle_batch(batch_id, BatchStatus::Running, BatchStatus::Queued,
              [] of ::Sebas::Platform::Store::Store::MemberMove)
            return
          end
          batch_id
        end

        private def dispatch_payload(batch_id : String) : String
          {batch_id: batch_id, session_key: @session_key}.to_json
        end

        # 接收序回填（admission 内定序：MAX+1，互斥下无竞态）
        private def finalize_env(env : InputEnvelope, seq : Int64) : InputEnvelope
          InputEnvelope.new(env.event_id, env.session_key, env.source, env.sender, seq,
            env.received_at, env.source_occurred_at, env.payload, env.policy_snapshot)
        end

        private def bump(name : String) : Nil
          @metrics[name] = (@metrics[name]? || 0_i64) + 1
        end
      end

      # 会话调度器注册表：session_key → SessionScheduler（懒创建，互斥保护）。
      # dispatch handler 由装配方在 Pool 就绪后回填（dispatch_to_pool 兜底拒绝未接线派发）。
      class Registry
        Log = Sebas::Log.for("sebas.scheduling.registry")

        @mutex = Mutex.new
        @schedulers = {} of String => SessionScheduler
        @dispatch_handler : SessionScheduler::DispatchFn? = nil

        def initialize(@store : ::Sebas::Platform::Store::Store)
        end

        # 装配接线（gateway initialize 在 build_pool 之后调用）
        def dispatch_handler=(fn : SessionScheduler::DispatchFn) : Nil
          @dispatch_handler = fn
        end

        def admit(env : InputEnvelope) : AdmissionReceipt
          scheduler_for(env.session_key).admit(env)
        end

        def batch_done(session_key : String, batch_id : String, failed_event_ids : Array(String) = [] of String) : Nil
          scheduler_for(session_key).batch_done(batch_id, failed_event_ids)
        end

        def batch_crashed(session_key : String, batch_id : String) : Nil
          scheduler_for(session_key).batch_crashed(batch_id)
        end

        # 启动重派：对有持久待发批次的会话逐个 kick（空闲守卫在 scheduler 内）
        def recover_dispatch : Int32
          sessions = @store.recoverable_batches.map(&.session_key)
          sessions.uniq!
          sessions.each { |session_key| scheduler_for(session_key).dispatch_if_idle }
          sessions.size
        end

        def shutdown : Nil
          @mutex.synchronize { @schedulers.each_value(&.shutdown) }
        end

        # 测试/观测面：指定会话的 scheduler（不存在则 nil）
        def scheduler?(session_key : String) : SessionScheduler?
          @mutex.synchronize { @schedulers[session_key]? }
        end

        private def scheduler_for(session_key : String) : SessionScheduler
          @mutex.synchronize do
            @schedulers[session_key] ||= SessionScheduler.new(session_key, @store,
              ->(key : String, payload : String) { dispatch_to_pool(key, payload) })
          end
        end

        private def dispatch_to_pool(session_key : String, payload : String) : Nil
          handler = @dispatch_handler
          raise "scheduling dispatch handler not wired (registry assembled before pool)" unless handler
          handler.call(session_key, payload)
        end
      end
    end
  end
end
