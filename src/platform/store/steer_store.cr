# frozen_string_literal: true

# busy steer 持久化（M4.5-WP4，自 store.cr 拆分——CodeRabbit RtP- 体量闸）：
# ::Sebas::Platform::Store::Store::SessionSteerRow record + steer 读写/状态迁移/组派发标记方法。
# DDL 仍在 store.cr 的 SCHEMA（唯一定义处），本文件只承载读写方法
# （ExpectationStoreMethods 同款 reopen 拆分模式）。
module Sebas
  module Platform
    # Store include 本 module 获得 steer 读写方法（include 行在 store.cr class Store 内）
    module SteerStoreMethods
      def session_batch(batch_id : String) : ::Sebas::Platform::Store::Store::SessionBatchRow?
        @db.query_one?(
          "SELECT batch_id, session_key, status, policy_snapshot, first_seq, last_seq, seal_reason FROM session_batches WHERE batch_id = ?",
          batch_id
        ) do |result_set|
          ::Sebas::Platform::Store::Store::SessionBatchRow.new(result_set.read(String), result_set.read(String), result_set.read(String),
            result_set.read(String), result_set.read(Int64), result_set.read(Int64), result_set.read(String?))
        end
      end

      # 启动恢复（契约 §5.2）：collecting → 立即按原快照 seal（recovery）；
      # sealed/queued → 重新入队；调用方据此分流。
      def collecting_batches(session_key : String? = nil) : Array(::Sebas::Platform::Store::Store::SessionBatchRow)
        if session_key
          query_batches("status = 'collecting' AND session_key = ?", session_key)
        else
          query_batches("status = 'collecting'")
        end
      end

      def recoverable_batches : Array(::Sebas::Platform::Store::Store::SessionBatchRow)
        query_batches("status IN ('sealed', 'queued')")
      end

      def batches_by_status(status : ::Sebas::Sessions::Scheduling::BatchStatus) : Array(::Sebas::Platform::Store::Store::SessionBatchRow)
        query_batches("status = ?", status.to_s)
      end

      private def query_batches(where : String, *params) : Array(::Sebas::Platform::Store::Store::SessionBatchRow)
        rows = [] of ::Sebas::Platform::Store::Store::SessionBatchRow
        @db.query("SELECT batch_id, session_key, status, policy_snapshot, first_seq, last_seq, seal_reason " \
                  "FROM session_batches WHERE #{where} ORDER BY first_seq", *params) do |result_set|
          result_set.each do
            rows << ::Sebas::Platform::Store::Store::SessionBatchRow.new(result_set.read(String), result_set.read(String), result_set.read(String),
              result_set.read(String), result_set.read(Int64), result_set.read(Int64), result_set.read(String?))
          end
        end
        rows
      end

      def batch_inputs(batch_id : String) : Array(::Sebas::Platform::Store::Store::SessionInputRow)
        rows = [] of ::Sebas::Platform::Store::Store::SessionInputRow
        @db.query(
          "SELECT i.event_id, i.session_key, i.source, i.sender, i.received_seq, i.received_at, " \
          "i.source_occurred_at, i.payload, i.policy_snapshot, i.status, i.batch_id " \
          "FROM session_inputs i JOIN session_batch_members m ON m.event_id = i.event_id " \
          "WHERE m.batch_id = ? ORDER BY m.position", batch_id
        ) do |result_set|
          result_set.each do
            rows << ::Sebas::Platform::Store::Store::SessionInputRow.new(result_set.read(String), result_set.read(String), result_set.read(String),
              result_set.read(String), result_set.read(Int64), result_set.read(String), result_set.read(String?),
              result_set.read(String), result_set.read(String), result_set.read(String), result_set.read(String?))
          end
        end
        rows
      end

      # ---- busy steer 持久化（accepted ≠ injected，契约 §4.4）----

      def record_session_steer(steer_id : String, session_key : String, target_turn_id : String,
                               target_generation : Int64, payload : String) : Bool
        rows = @db.exec(
          "INSERT OR IGNORE INTO session_steers (steer_id, session_key, target_turn_id, target_generation, payload, status, created_at, updated_at) " \
          "VALUES (?, ?, ?, ?, ?, 'accepted', ?, ?)",
          steer_id, session_key, target_turn_id, target_generation, payload, now, now
        ).rows_affected
        rows > 0
      end

      def transition_session_steer(steer_id : String, from : ::Sebas::Sessions::Scheduling::SteerStatus,
                                   to : ::Sebas::Sessions::Scheduling::SteerStatus, reason : String? = nil) : Bool
        changed = @db.exec("UPDATE session_steers SET status = ?, reason = ?, updated_at = ? " \
                           "WHERE steer_id = ? AND status = ?",
          to.to_s, reason, now, steer_id, from.to_s).rows_affected
        changed > 0
      end

      def session_steers(session_key : String, status : String? = nil) : Array(::Sebas::Platform::Store::Store::SessionSteerRow)
        rows = [] of ::Sebas::Platform::Store::Store::SessionSteerRow
        if status
          @db.query("SELECT steer_id, session_key, target_turn_id, target_generation, payload, status, reason, created_at, dispatch_event_id " \
                    "FROM session_steers WHERE session_key = ? AND status = ? ORDER BY created_at, rowid",
            session_key, status) do |result_set|
            result_set.each { rows << read_steer(result_set) }
          end
        else
          @db.query("SELECT steer_id, session_key, target_turn_id, target_generation, payload, status, reason, created_at, dispatch_event_id " \
                    "FROM session_steers WHERE session_key = ? ORDER BY created_at, rowid", session_key) do |result_set|
            result_set.each { rows << read_steer(result_set) }
          end
        end
        rows
      end

      # 组派发标记（M4.5-WP4 四轮 RB-Q）：单条 UPDATE 原子写组内全部行——
      # 崩溃后恢复按 dispatch_event_id 找回原组沿用原 event_id（admission
      # duplicate 幂等），不按剩余成员重算组头防重复派发。部分命中（并发
      # 确认）返回 false 跳过本轮。
      def mark_steer_dispatch_group(steer_ids : Array(String), event_id : String) : Bool
        # 事务内逐行 UPDATE（IN 数组绑定 statement 不支持）；任一行非
        # queued 即 raise DB::Rollback → 事务回滚（块内 return 不回滚，
        # crystal-db ensure 会提交——CodeRabbit RtQF），组标记原子生效
        complete = true
        @db.transaction do |tx|
          steer_ids.each do |id|
            rows = tx.connection.exec(
              "UPDATE session_steers SET dispatch_event_id = ?, updated_at = ? " \
              "WHERE steer_id = ? AND status = 'queued'",
              event_id, now, id
            ).rows_affected
            unless rows == 1
              complete = false
              raise ::DB::Rollback.new
            end
          end
        end
        complete
      end

      # 跨会话按状态查（WP4：expire_due 超时扫描 / recovery unknown_not_injected 收敛）
      def steers_with_status(status : String) : Array(::Sebas::Platform::Store::Store::SessionSteerRow)
        rows = [] of ::Sebas::Platform::Store::Store::SessionSteerRow
        @db.query("SELECT steer_id, session_key, target_turn_id, target_generation, payload, status, reason, created_at, dispatch_event_id " \
                  "FROM session_steers WHERE status = ? ORDER BY created_at, rowid", status) do |result_set|
          result_set.each { rows << read_steer(result_set) }
        end
        rows
      end

      private def read_steer(result_set : ::DB::ResultSet) : ::Sebas::Platform::Store::Store::SessionSteerRow
        ::Sebas::Platform::Store::Store::SessionSteerRow.new(result_set.read(String), result_set.read(String), result_set.read(String),
          result_set.read(Int64), result_set.read(String), result_set.read(String), result_set.read(String?),
          result_set.read(String), result_set.read(String?))
      end
    end
  end
end
