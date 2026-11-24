require "./policy"

# 会话输入调度：类型、状态机与纯函数（session-input-scheduling.md §4/§5.1；M3-WP1 承载）
#
# 状态机（契约 §4.1）：
#   Input：accepted → batched → dispatched → done，另有明确 failed
#   Batch：collecting → sealed → queued → running → done/failed
#   Steer：accepted → injected，或 accepted → queued / expired / rejected
# 全部迁移经 TRANSITIONS 表判定；「输入已接受」与「LLM 已看到」是两个状态，
# 不得折叠（accepted/batched ≠ dispatched done）。
module Sebas
  module Sessions
    module Scheduling
      extend self
      enum InputStatus
        Accepted
        Batched
        Dispatched
        Done
        Failed

        def to_s : String
          super.downcase
        end
      end

      enum BatchStatus
        Collecting
        Sealed
        Queued
        Running
        Done
        Failed

        def to_s : String
          super.downcase
        end
      end

      enum SteerStatus
        Accepted
        Injected
        Queued
        Dispatched # 已合成入站事件并入持久批次（queued 的消费终态，M4.5-WP4）
        Expired
        Rejected

        def to_s : String
          super.downcase
        end
      end

      # seal 原因（契约 §5.1 session_batches.seal_reason；shutdown/recovery 为调用方
      # 驱动的保守 seal，不经 eval_seal 产生）
      enum SealReason
        Idle
        MaxWait
        Count
        Bytes
        Flush
        TurnEnd
        Shutdown
        Recovery

        def to_s : String
          super.downcase
        end
      end

      # ---- 迁移表（表驱动，纯函数判定）----

      INPUT_TRANSITIONS = {
        {"accepted", "batched"}, {"accepted", "failed"},
        {"batched", "dispatched"}, {"batched", "failed"},
        {"dispatched", "done"}, {"dispatched", "failed"},
      }
      BATCH_TRANSITIONS = {
        {"collecting", "sealed"}, {"collecting", "failed"},
        {"sealed", "queued"}, {"sealed", "failed"},
        {"queued", "running"}, {"queued", "failed"},
        {"running", "done"}, {"running", "failed"},
      }
      STEER_TRANSITIONS = {
        {"accepted", "injected"}, {"accepted", "queued"},
        {"accepted", "expired"}, {"accepted", "rejected"},
        {"queued", "dispatched"}, {"queued", "rejected"}, # queued=持久 outbox，派发确认后终结（M4.5-WP4）
      }

      def valid_input_transition?(from : InputStatus, to : InputStatus) : Bool
        INPUT_TRANSITIONS.includes?({from.to_s, to.to_s})
      end

      def valid_batch_transition?(from : BatchStatus, to : BatchStatus) : Bool
        BATCH_TRANSITIONS.includes?({from.to_s, to.to_s})
      end

      def valid_steer_transition?(from : SteerStatus, to : SteerStatus) : Bool
        STEER_TRANSITIONS.includes?({from.to_s, to.to_s})
      end

      # ---- 核心数据结构（契约 §4.3）----

      # 输入信封：原始 envelope 永久可查（不只保存拼接文本）
      record InputEnvelope,
        event_id : String, session_key : String, source : String, sender : String,
        received_seq : Int64, received_at : String, source_occurred_at : String?,
        payload : String, policy_snapshot : PolicySnapshot

      # 批次：batch_id 由 session 与持久序号生成，不依赖拼接文本 hash（契约 §4.2）
      record Batch,
        batch_id : String, session_key : String, status : BatchStatus,
        policy_snapshot : PolicySnapshot, first_seq : Int64, last_seq : Int64,
        created_at : String, sealed_at : String?, seal_reason : String?

      record BatchMember, event_id : String, batch_id : String, position : Int64

      # admission 回执：首次返回 accepted + 排队位（若已知）；
      # collecting/queued/running 是批次状态，不与 admission ACK 混用
      record AdmissionReceipt, event_id : String, batch_id : String, status : String, queue_position : Int32?

      record SteerReceipt, steer_id : String, target_turn_id : String, target_generation : Int64,
        status : SteerStatus, reason : String?

      record TurnLease, session_key : String, turn_id : String, generation : Int64

      # ---- seal 条件评估（契约 §4.3；纯函数，时钟由调用方注入）----
      #
      # collecting 批次的累积状态（单调时钟毫秒；墙钟仅持久展示）。
      record BatchAccumulator,
        first_received_ms : Int64, last_received_ms : Int64,
        message_count : Int32, byte_count : Int64, sealed : Bool = false

      # seal 条件（任一满足即返回对应 reason；nil = 继续 collecting）：
      #   显式 flush > turn_end flush > bytes > count > max_wait（不被新消息重置）> idle
      #   （idle_ms=0 时 idle 条件禁用，仅由其余条件封冻；可被新输入重置是
      #    last_received_ms 的语义——每条新输入调用方更新它）
      def eval_seal(acc : BatchAccumulator, policy : PolicySnapshot, now_ms : Int64,
                    explicit_flush : Bool = false, prior_turn_ended : Bool = false) : SealReason?
        return if acc.sealed
        return SealReason::Flush if explicit_flush
        return SealReason::TurnEnd if policy.flush_on_turn_end? && prior_turn_ended
        return SealReason::Bytes if acc.byte_count >= policy.max_bytes
        return SealReason::Count if acc.message_count >= policy.max_messages
        return SealReason::MaxWait if now_ms - acc.first_received_ms >= policy.max_wait_ms
        return if policy.idle_ms == 0 # idle 条件禁用（契约 §4.3）
        return SealReason::Idle if now_ms - acc.last_received_ms >= policy.idle_ms
        nil
      end

      # ---- 字节预算 admission（契约 §4.3 字节预算 admission）----
      #
      # :append       → 加入当前 collecting 批次
      # :seal_then_new→ 先 seal 当前批（seal_reason: bytes），输入开启新批（不丢弃）
      # :reject       → 单条自身超过 max_bytes 硬限制，明确拒绝
      enum AdmitDecision
        Append
        SealThenNew
        Reject
      end

      def admit_decision(current_batch_bytes : Int64, incoming_bytes : Int64, max_bytes : Int64) : AdmitDecision
        return AdmitDecision::Reject if incoming_bytes > max_bytes
        return AdmitDecision::SealThenNew if current_batch_bytes + incoming_bytes > max_bytes
        AdmitDecision::Append
      end

      # ---- 聚合桶键（契约 §4.3；按 group_by 取值定义）----
      #
      # sender（默认）：session + 发送者/来源 + 安全上下文隔离；
      # session：跨发送者合并，但保留每成员署名与安全上下文（桶键仅隔离安全上下文）。
      def bucket_key(group_by : String, session_key : String, sender : String,
                     source : String, security_context : String) : String
        base = "#{session_key}\u{1f}"
        case group_by
        when "session" then base + "ctx=#{security_context}"
        else                base + "sender=#{sender}\u{1f}source=#{source}\u{1f}ctx=#{security_context}"
        end
      end

      # batch_id 由 session 与持久接收序号生成（契约 §4.2：不依赖拼接文本 hash）
      def batch_id_for(session_key : String, first_seq : Int64) : String
        "#{session_key}:batch:#{first_seq}"
      end
    end
  end
end
