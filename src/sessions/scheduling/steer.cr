require "json"
require "mutex"
require "../../../src/platform/store/store"
require "./envelope"
require "./policy"

module Sebas
  module Sessions
    module Scheduling
      # 活跃 turn 注册表（M4.5-WP4/#6）：session → TurnLease（turn_id +
      # generation）。generation 每 session 单调递增，注册新 turn 时 +1——
      # 旧 generation 的 steer 不可注入新 turn（验收：压缩/reset 语义的
      # 最小等价物；显式 session reset 另卡）。
      class TurnRegistry
        @leases = Hash(String, TurnLease).new
        @generations = Hash(String, Int64).new
        @mutex = Mutex.new

        # 注册 turn：generation 递增并发放 lease（进程内权威发放者）
        def register(session_key : String, turn_id : String) : TurnLease
          @mutex.synchronize do
            generation = (@generations[session_key]? || 0_i64) + 1_i64
            @generations[session_key] = generation
            lease = TurnLease.new(session_key, turn_id, generation)
            @leases[session_key] = lease
            lease
          end
        end

        def lease(session_key : String) : TurnLease?
          @mutex.synchronize { @leases[session_key]? }
        end

        # 注销：仅当 turn_id 仍匹配才清（防迟到结束覆盖新 turn 的 lease）
        def unregister(session_key : String, turn_id : String) : Nil
          @mutex.synchronize do
            lease = @leases[session_key]?
            @leases.delete(session_key) if lease && lease.turn_id == turn_id
          end
        end

        def matches?(session_key : String, turn_id : String, generation : Int64) : Bool
          lease = lease(session_key)
          !lease.nil? && lease.turn_id == turn_id && lease.generation == generation
        end
      end

      # Steer 中心（M4.5-WP4/#6）：pending correction 先持久化再入队；
      # 提交判定目标 turn（显式指定或绑定当前活跃 lease），generation 不
      # 匹配/无活跃 turn 自动转 queued 后续批次；drain 只在 turn 轮边界
      # 发生（工具不被取消、参数不被篡改）；崩溃窗口保守口径——CAS injected
      # 后 transcript 落标记行，恢复扫描无标记即 unknown_not_injected 转 queued。
      class SteerCenter
        Log = ::Sebas::Log.for("sebas.scheduling.steer")

        # 降级转 queued 后的投递清单项（gateway 合成入站事件组后续批次）
        record SteerDispatch, steer_id : String, session_key : String, payload : String

        # 状态迁移事件回调（M4.5-WP6 SSE）：(event, payload)
        setter on_transition : Proc(String, ::JSON::Any, Nil)?

        def initialize(@store : ::Sebas::Platform::Store::Store, @registry : TurnRegistry,
                       @policy : Proc(String, PolicySnapshot), @now : -> ::Time = -> { ::Time.utc })
        end

        # 提交（管理面 sessions.steer / 显式 /steer 命令；普通聊天正文不猜纠偏意图）。
        # 先落库（accepted）再判定目标：无活跃 turn 或 generation 不匹配 → queued。
        # 提交判级（顺序即优先级）：禁用/空 payload 拒绝；无活跃 turn 或显式
        # target 与活跃不一致降级 queued；堆积上限显式拒绝（§4.4 不静默覆盖）
        private def classify(session_key : String, policy : PolicySnapshot, payload : String,
                             lease : TurnLease?, target_turn_id : String?,
                             target_generation : Int64?) : Tuple(SteerStatus, String?)
          if !policy.steer_enabled?
            {SteerStatus::Rejected, "steer disabled"}
          elsif payload.strip.empty?
            {SteerStatus::Rejected, "empty payload"}
          elsif lease.nil?
            {SteerStatus::Queued, "no_active_turn"}
          elsif target_turn_id && lease && target_turn_id != lease.turn_id
            {SteerStatus::Queued, "turn_mismatch"} # 显式 turn 与活跃不一致：永不命中 drain/flush
          elsif target_generation && target_generation != lease.generation
            {SteerStatus::Queued, "generation_mismatch"}
          elsif @store.session_steers(session_key, "accepted").size >= policy.steer_max_pending_messages
            {SteerStatus::Rejected, "pending limit exceeded"}
          else
            {SteerStatus::Accepted, nil}
          end
        end

        # 提交判级（先落库 accepted 再 CAS 到非终态目标——全状态留审计行）
        def submit(session_key : String, payload : String,
                   target_turn_id : String? = nil, target_generation : Int64? = nil,
                   steer_id : String = "steer-#{Random::Secure.hex(6)}") : SteerReceipt
          policy = @policy.call(session_key)
          lease = @registry.lease(session_key)
          turn_id = target_turn_id || lease.try(&.turn_id) || ""
          generation = target_generation || lease.try(&.generation) || 0_i64

          status, reason = classify(session_key, policy, payload, lease,
            target_turn_id, target_generation)

          @store.record_session_steer(steer_id, session_key, turn_id, generation, payload)
          unless status == SteerStatus::Accepted
            @store.transition_session_steer(steer_id, SteerStatus::Accepted, status, reason)
          end
          emit("steer.#{status}", {"session_key" => ::JSON::Any.new(session_key),
                                   "steer_id"    => ::JSON::Any.new(steer_id),
                                   "reason"      => ::JSON::Any.new(reason || "")})
          SteerReceipt.new(steer_id, turn_id, generation, status, reason)
        end

        # turn 轮边界 drain（AgentRuntime 固定顺序：工具结果落库 → drain →
        # 下一次模型调用）。lease 不匹配（迟到/换代）保守不注入；注入 =
        # CAS accepted→injected（失败=并发已转态，跳过）→ transcript 落
        # steer 标记行（审计可重放 + 崩溃恢复依据）→ 返回注入文本。
        def drain(session_key : String, turn_id : String, generation : Int64) : Array(String)
          return [] of String unless @registry.matches?(session_key, turn_id, generation)
          injected = [] of String
          @store.session_steers(session_key, "accepted").each do |row|
            next unless row.target_turn_id == turn_id && row.target_generation == generation
            if steer_expired?(row)
              @store.transition_session_steer(row.steer_id, SteerStatus::Accepted, SteerStatus::Queued,
                "max_wait exceeded")
              next
            end
            unless @store.transition_session_steer(row.steer_id, SteerStatus::Accepted,
                     SteerStatus::Injected, "injected at turn boundary")
              next # 并发转态（过期扫描/另一 drain），不重复注入
            end
            @store.append_transcript(session_key, "user", steer_marker(row))
            emit("steer.injected", {"session_key" => ::JSON::Any.new(session_key),
                                    "steer_id"    => ::JSON::Any.new(row.steer_id)})
            injected << "[steer #{row.steer_id}] #{row.payload}"
          end
          injected
        end

        # turn 结束（finally）：本 turn 未注入的 pending 全部转 queued 后续
        # 批次（验收：无工具边界/turn 已结束自动进入后续批次，不丢消息）。
        # 返回 queued 的 payload（接收顺序），调用方可组后续批次。
        # turn 结束（finally）：本 turn 未注入的 pending 全部转 queued 后续
        # 批次（验收：无工具边界/turn 已结束自动进入后续批次，不丢消息）。
        # 返回降级清单（接收顺序），调用方合成入站事件组后续批次。
        def flush_to_queue(session_key : String, turn_id : String) : Array(SteerDispatch)
          downgraded = [] of SteerDispatch
          @store.session_steers(session_key, "accepted").each do |row|
            next unless row.target_turn_id == turn_id
            if @store.transition_session_steer(row.steer_id, SteerStatus::Accepted,
                 SteerStatus::Queued, "turn ended before injection")
              downgraded << SteerDispatch.new(row.steer_id, session_key, row.payload)
            end
          end
          downgraded
        end

        # 过期扫描（100ms 协程粒度）：accepted 超过 steer.max_wait_ms 的行
        # 转 queued 后续批次（不等下一个 turn 边界）。
        def expire_due : Array(SteerDispatch)
          downgraded = [] of SteerDispatch
          @store.steers_with_status("accepted").each do |row|
            next unless steer_expired?(row)
            if @store.transition_session_steer(row.steer_id, SteerStatus::Accepted, SteerStatus::Queued,
                 "max_wait exceeded")
              downgraded << SteerDispatch.new(row.steer_id, row.session_key, row.payload)
            end
          end
          downgraded
        end

        private def emit(event : String, payload : Hash(String, ::JSON::Any)) : Nil
          @on_transition.try(&.call(event, ::JSON::Any.new(payload)))
        rescue
          nil
        end

        private def steer_expired?(row : ::Sebas::Platform::Store::Store::SessionSteerRow) : Bool
          max_wait_ms = @policy.call(row.session_key).steer_max_wait_ms
          created = ::Time.parse_rfc3339(row.created_at)
          (@now.call - created) > max_wait_ms.milliseconds
        rescue ex
          Log.error(exception: ex) { "steer expiry check failed: #{row.steer_id}" }
          false
        end

        # 注入标记（审计可重放 + 崩溃恢复依据）：恢复扫描按 "[steer <id> "
        # 前缀核对——transcript 无标记 = 崩溃在 CAS 后落标前。
        private def steer_marker(row : ::Sebas::Platform::Store::Store::SessionSteerRow) : String
          "[steer #{row.steer_id} turn=#{row.target_turn_id} gen=#{row.target_generation}] #{row.payload}"
        end

        # 恢复口径（recovery 调用，重启后无活跃 turn）：①injected 行
        # transcript 无标记 → queued（unknown_not_injected，保守不伪报成功）；
        # ②accepted 未注入行全部转 queued 后续批次（§5.2，原因落审计）。
        def recover_unconfirmed : Array(SteerDispatch)
          downgraded = [] of SteerDispatch
          @store.steers_with_status("injected").each do |entry|
            marked = @store.transcripts(entry.session_key).any? do |transcript|
              transcript.role == "user" && transcript.content.starts_with?("[steer #{entry.steer_id} ")
            end
            next if marked
            if @store.transition_session_steer(entry.steer_id, SteerStatus::Injected, SteerStatus::Queued,
                 "unknown_not_injected")
              downgraded << SteerDispatch.new(entry.steer_id, entry.session_key, entry.payload)
              Log.warn { "steer #{entry.steer_id} downgraded to queued (unknown_not_injected)" }
            end
          end
          @store.steers_with_status("accepted").each do |entry|
            if @store.transition_session_steer(entry.steer_id, SteerStatus::Accepted, SteerStatus::Queued,
                 "recovery_no_active_turn")
              downgraded << SteerDispatch.new(entry.steer_id, entry.session_key, entry.payload)
            end
          end
          downgraded
        end
      end
    end
  end
end
