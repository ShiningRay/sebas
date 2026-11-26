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
        Log = Sebas::Log.for("scheduling.scheduler")

        getter session_key : String

        # dispatch 回调：session_key + 批次派发 payload（JSON），由装配方投递给执行体。
        # 返回后批次即在途（queued→running 已迁移）；执行完成必须回调 batch_done。
        alias DispatchFn = String, String -> Nil

        @mutex = Mutex.new
        @running_batch : String? = nil
        @stopping = false
        @metrics : Hash(String, Int64)

        # debounce 聚合桶（M4.1→WP3，#5）：bucket_key → 累积状态。
        # 单调时钟毫秒由 @clock 注入（契约：时钟逻辑可注入，墙钟仅持久展示）。
        @buckets = Hash(String, BatchAccumulator).new
        @bucket_inputs = Hash(String, Array(InputEnvelope)).new
        @bucket_batch_ids = Hash(String, String).new
        @clock : -> Int64

        # 状态迁移事件回调（M4.5-WP6 SSE）：(event_name, payload)——nil = 未接线
        setter on_transition : Proc(String, ::JSON::Any, Nil)?

        def initialize(@session_key : String, @store : ::Sebas::Platform::Store::Store,
                       @dispatch : DispatchFn, clock : (-> Int64)? = nil)
          @metrics = {
            "admitted"          => 0_i64,
            "duplicate"         => 0_i64,
            "rejected_capacity" => 0_i64,
            "dispatched"        => 0_i64,
            "completed"         => 0_i64,
            "sealed_idle"       => 0_i64,
            "sealed_max_wait"   => 0_i64,
            "sealed_count"      => 0_i64,
            "sealed_bytes"      => 0_i64,
            "sealed_flush"      => 0_i64,
            "sealed_turn_end"   => 0_i64,
          } of String => Int64
          process_start = ::Time.instant
          @clock = clock || -> { process_start.elapsed.total_milliseconds.to_i64 }
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
              confirm_telegram_dispatch(env)
              Log.debug { "admission duplicate (session=#{@session_key} event=#{env.event_id})" }
              return AdmissionReceipt.new(env.event_id, "", "duplicate", nil)
            end

            load = @store.pending_load(@session_key)
            incoming_bytes = env.payload.bytesize.to_i64

            # 单条自身超批字节预算：明确拒绝（契约 §4.3 字节预算 admission）
            if incoming_bytes > snapshot.max_bytes
              bump("rejected_capacity")
              Log.error { "admission rejected (event dropped): input exceeds batch max_bytes (session=#{@session_key} event=#{env.event_id} bytes=#{incoming_bytes} limit=#{snapshot.max_bytes})" }
              return AdmissionReceipt.new(env.event_id, "", "rejected", nil)
            end

            # 会话积压容量（queue.max_pending_batches / queue.max_pending_bytes）
            if load.batches + 1 > snapshot.max_pending_batches || load.bytes + incoming_bytes > snapshot.max_pending_bytes
              bump("rejected_capacity")
              Log.error { "admission rejected (event dropped): session backlog at capacity (session=#{@session_key} event=#{env.event_id} pending_batches=#{load.batches}/#{snapshot.max_pending_batches} pending_bytes=#{load.bytes}/#{snapshot.max_pending_bytes})" }
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

            # debounce 模式（WP3，#5）：入聚合桶，eval_seal 即刻判定（bytes/count
            # 立即封冻；idle/max_wait 由 seal_due 扫描器收口）。忙碌期聚合：批次
            # 收集不依赖会话空闲，turn 运行中照常入桶。
            if snapshot.batch_mode == "debounce"
              return admit_debounce(batch, env, snapshot, seq)
            end

            # 批次行 + 首个输入同一事务：崩溃不留孤儿空批（batch_id 序号不被占用）
            unless @store.admit_new_batch(batch, env, 0)
              # 主键守卫兜底（同 session 已互斥，理论不可达）：事务已回滚，零残留
              bump("duplicate")
              confirm_telegram_dispatch(env)
              Log.debug { "admission duplicate via pk guard (session=#{@session_key} event=#{env.event_id})" }
              return AdmissionReceipt.new(env.event_id, batch.batch_id, "duplicate", nil)
            end

            # queue 模式：每消息独立批次，admit 成功后立即 seal（flush）并入队
            seal_and_queue(batch.batch_id, SealReason::Flush)
            # 空闲即派发；回执排队位 = 本批之前的 pending 批数（自身被派发则为 0）
            # batch.queued 已在 seal_and_queue 共享路径发送（hlIz）
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

        # telegram 恢复记录补确认（M3-WP8 提案 §4.2「已有 admission 的恢复记录补确认」）：
        # duplicate 重投时先查该 event_id 对应 intent 是否已持久化（done/dispatched），
        # 已持久化才置 telegram_updates.dispatched=true；不存在时保留 false——由调度器
        # failed 批次重试扩展（#252）的恢复路径处理，不提前确认（避免 record_intent
        # 失败后无法被扫描恢复）。本操作在 admit 内部完成，不绕过会话串行约束。
        private def confirm_telegram_dispatch(env : InputEnvelope) : Nil
          @store.confirm_telegram_dispatch(env.event_id) if env.source == "telegram"
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
            emit("batch.settled", {"session_key" => ::JSON::Any.new(@session_key),
                                   "batch_id"    => ::JSON::Any.new(batch_id),
                                   "failed"      => ::JSON::Any.new(failed_event_ids.size.to_i64)})
            flush_on_turn_end_buckets
            dispatch_locked
          end
        end

        # 显式 flush 入口（契约 §4.3：显式 flush > 其余条件，不等 debounce）：
        # 逐桶立即封存。返回封存桶数。
        # 指标快照（M4.5-WP6 metrics.scheduling）：内存计数器只读副本
        def metrics_snapshot : Hash(String, Int64)
          @mutex.synchronize { @metrics.dup }
        end

        # 在途批次（运行中 batch id；无则 nil）
        def in_flight_batch : String?
          @mutex.synchronize { @running_batch }
        end

        private def emit(event : String, payload : Hash(String, ::JSON::Any)) : Nil
          @on_transition.try(&.call(event, ::JSON::Any.new(payload)))
        rescue
          nil # 事件不反噬调度主链
        end

        def flush_all_buckets : Int32
          @mutex.synchronize do
            sealed = 0
            @bucket_batch_ids.keys.dup.each do |key|
              snapshot = snapshot_for_limit_check
              next unless snapshot
              seal_bucket(key, snapshot, SealReason::Flush)
              sealed += 1
            end
            sealed
          end
        end

        # turn 结束封存：flush_on_turn_end? 为真的桶即刻收口（CodeRabbit——
        # 原 eval_seal 的 prior_turn_ended 参数未接线，指标恒 0）。
        # turn 结束封存（batch_done 回调内接线；测试/观测亦可直调）。
        def flush_on_turn_end_buckets : Nil
          @buckets.reject! do |key, _acc|
            snapshot = @bucket_inputs[key]?.try(&.first?).try(&.policy_snapshot)
            next false unless snapshot
            next false unless snapshot.flush_on_turn_end?
            batch_id = @bucket_batch_ids[key]?
            next false unless batch_id
            seal_and_queue(batch_id, SealReason::TurnEnd)
            bump("sealed_turn_end")
            @bucket_inputs.delete(key)
            @bucket_batch_ids.delete(key)
            true
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
            emit("batch.settled", {"session_key" => ::JSON::Any.new(@session_key),
                                   "batch_id"    => ::JSON::Any.new(batch_id),
                                   "failed"      => ::JSON::Any.new(true),
                                   "crash"       => ::JSON::Any.new(true)})
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

        # ---- debounce 聚合（WP3，#5）----

        # debounce admission（#5）：桶已存在 → admit_session_input 追加进该桶
        # 批次行；桶不存在 → admit_new_batch 建批（首输入）。入桶后即时判定
        # bytes/count/max_wait；idle 由 seal_due 扫描器收口。忙碌期照常聚合
        # （不依赖会话空闲，不饥饿）。
        private def admit_debounce(batch : Batch, env : InputEnvelope,
                                   snapshot : PolicySnapshot, seq : Int64) : AdmissionReceipt
          key = ::Sebas::Sessions::Scheduling.bucket_key(
            snapshot.group_by, @session_key, env.sender, env.source, "default")
          env = finalize_env(env, seq)

          persisted_batch_id = batch.batch_id # 追加路径覆写为已持久化的桶批次
          if existing = @bucket_inputs[key]?
            # 追加进既有桶批次行（状态守卫：桶批次仍 collecting 才接受）
            batch_id = @bucket_batch_ids[key]?
            batch_row = batch_id && collecting_batch_for(batch_id)
            unless batch_row && @store.admit_session_input(env, batch_row, existing.size)
              bump("rejected_capacity")
              return AdmissionReceipt.new(env.event_id, batch.batch_id, "rejected", nil)
            end
            # 回执 batch_id = 已持久化的桶批次（新构造的 batch 未落库，CodeRabbit 幽灵批次）
            persisted_batch_id = batch_id
            raise ::Sebas::Platform::Store::StoreError.new("桶批次 id 缺失（内部状态不一致）") if persisted_batch_id.nil?
          else
            # 首输入建批（批次行 + 输入同一事务，崩溃不留孤儿空批）
            unless @store.admit_new_batch(batch, env, 0)
              bump("duplicate")
              confirm_telegram_dispatch(env)
              return AdmissionReceipt.new(env.event_id, batch.batch_id, "duplicate", nil)
            end
            @bucket_batch_ids[key] = batch.batch_id # 桶键 ↔ 批次行关联
          end

          now_ms = @clock.call
          acc = @buckets[key]? || BatchAccumulator.new(now_ms, now_ms, 0, 0)
          acc = BatchAccumulator.new(acc.first_received_ms, now_ms,
            acc.message_count + 1, acc.byte_count + env.payload.bytesize.to_i64)
          @buckets[key] = acc
          (@bucket_inputs[key] ||= [] of InputEnvelope) << env

          # 即时条件：bytes / count / max_wait（idle 由扫描器收口）
          reason = ::Sebas::Sessions::Scheduling.eval_seal(acc, snapshot, now_ms)
          if reason && {SealReason::Bytes, SealReason::Count, SealReason::MaxWait}.includes?(reason)
            seal_bucket(key, snapshot, reason)
          end
          # max_active_buckets 消费：超限封存最老桶（admit 路径也生效，CodeRabbit）
          enforce_bucket_limit(snapshot_for_limit_check)
          bump("admitted")
          AdmissionReceipt.new(env.event_id, persisted_batch_id, "accepted", nil)
        end

        # 桶 → collecting 批次（SessionBatchRow.policy_snapshot 反序列化重建
        # Batch——admit_session_input 需要完整 Batch 值对象）。
        private def collecting_batch_for(batch_id : String) : Batch?
          row = @store.collecting_batches(@session_key).find(&.batch_id.==(batch_id))
          return unless row
          snapshot = ::Sebas::Sessions::Scheduling::PolicySnapshot.from_json(row.policy_snapshot)
          Batch.new(batch_id: row.batch_id, session_key: row.session_key,
            status: BatchStatus::Collecting, policy_snapshot: snapshot,
            first_seq: row.first_seq, last_seq: row.last_seq,
            created_at: "", sealed_at: nil, seal_reason: row.seal_reason)
        end

        # seal 扫描（定时器/显式调用）：idle/max_wait 到期的桶封冻入队。
        # max_active_buckets 消费：桶数超上限时强制封存最老桶（LRU 近似：首建时间最早）。
        def seal_due(now_ms : Int64? = nil) : Int32
          @mutex.synchronize do
            now = now_ms || @clock.call
            sealed = 0
            # 先收集到期桶再封存（CodeRabbit）：遍历中调 seal_bucket 会删当前
            # 条目，reject! 的 @size/@indices 双重处理可致计数错乱甚至挂起。
            due = [] of {String, PolicySnapshot, SealReason}
            @buckets.each do |key, acc|
              snapshot = @bucket_inputs[key]?.try(&.first?).try(&.policy_snapshot)
              next unless snapshot
              reason = ::Sebas::Sessions::Scheduling.eval_seal(acc, snapshot, now)
              if reason && {SealReason::Idle, SealReason::MaxWait}.includes?(reason)
                due << {key, snapshot, reason}
              end
            end
            due.each do |key, snapshot, reason|
              seal_bucket(key, snapshot, reason)
              sealed += 1
            end
            # max_active_buckets：封存最老桶防桶数失控（契约 §4.3）
            enforce_bucket_limit(snapshot_for_limit_check)
            sealed
          end
        end

        private def snapshot_for_limit_check : PolicySnapshot?
          @bucket_inputs.each_value.first?.try(&.first?).try(&.policy_snapshot)
        end

        private def enforce_bucket_limit(snapshot : PolicySnapshot?) : Nil
          return unless snapshot
          limit = snapshot.max_active_buckets
          while @buckets.size > limit
            oldest = @buckets.min_by { |_, acc| acc.first_received_ms }
            seal_bucket(oldest[0], snapshot, SealReason::MaxWait)
            @buckets.delete(oldest[0])
          end
        end

        # 封冻聚合桶 → collecting 批次 seal + queued（结构化成员已在批次输入里，
        # 原始 envelope 永久可查——dispatch payload 只带 batch_id，拼接视图由
        # 执行体按 batch_inputs 构造）。
        private def seal_bucket(key : String, snapshot : PolicySnapshot, reason : SealReason) : Nil
          inputs = @bucket_inputs.delete(key)
          @buckets.delete(key)
          batch_id = @bucket_batch_ids.delete(key)
          return if inputs.nil? || inputs.empty? || batch_id.nil?

          seal_and_queue(batch_id, reason)
          bump("sealed_#{reason.to_s.downcase}")
          dispatch_locked # 空闲即扫：封存即可派发（不饥饿）
        end

        # ---- 内部（调用方须持 @mutex）----

        # seal + 入队（受守卫迁移，竞态由状态守卫兜底）。sealed 事件在共享
        # 路径发送（gzkQ：flush_on_turn_end/queue admission/shutdown 全覆盖，
        # 迁移成功才发）
        private def seal_and_queue(batch_id : String, reason : SealReason) : Nil
          sealed = @store.transition_session_batch(batch_id, BatchStatus::Collecting,
            BatchStatus::Sealed, reason.to_s)
          queued = @store.transition_session_batch(batch_id, BatchStatus::Sealed, BatchStatus::Queued)
          if sealed
            emit("batch.sealed", {"session_key" => ::JSON::Any.new(@session_key),
                                  "batch_id"    => ::JSON::Any.new(batch_id),
                                  "reason"      => ::JSON::Any.new(reason.to_s.downcase)})
          end
          # queued 事件在共享入队路径发送（hlIz：覆盖 debounce seal_due 路径；
          # queue admission 处删除避免 started→queued 逆序）
          if queued
            emit("batch.queued", {"session_key" => ::JSON::Any.new(@session_key),
                                  "batch_id"    => ::JSON::Any.new(batch_id)})
          end
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
          emit("batch.started", {"session_key" => ::JSON::Any.new(@session_key),
                                 "batch_id"    => ::JSON::Any.new(batch_id)})
          begin
            @dispatch.call(@session_key, dispatch_payload(batch_id))
          rescue ex
            # 交接失败（如 pool 已关）：批次回退 queued 保持可重试，清在途标记。
            # 成员同步回 batched——否则二次派发时 Batched→Dispatched 迁移 0 行
            # 导致 dispatch 返回 nil、批次卡 running（#153 复审捕获）。
            Log.error(exception: ex) { "dispatch handoff failed, batch requeued (session=#{@session_key} batch=#{batch_id})" }
            @running_batch = nil
            @store.settle_batch(batch_id, BatchStatus::Running, BatchStatus::Queued,
              [::Sebas::Platform::Store::Store::MemberMove.new(InputStatus::Dispatched, InputStatus::Batched, nil)])
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
    end
  end
end
