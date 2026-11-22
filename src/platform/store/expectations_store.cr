# frozen_string_literal: true

# expectations 持久化（M4.1-WP2）：Store 的 reopen 拆分——
# DDL 仍在 store.cr 的 SCHEMA（唯一定义处），本文件只承载读写方法，
# 减少大型 Store 文件的修改耦合（CodeRabbit 拆分建议）。
module Sebas
  module Platform
    # Store include 本 module 获得_expectations 读写方法（拆分自 store.cr，
    # include 行在 store.cr class Store 内）。
    module ExpectationStoreMethods
      # --- expectations（M4.1-WP2：join 汇聚点落库面） ---

      def insert_expectation(row : ::Sebas::Orchestration::Fork::ExpectationRow) : Nil
        @db.exec(
          "INSERT INTO expectations (id, fork_id, parent_task_id, parent_session, mode, deadline, members, settled_count, status, result, created_at, updated_at) " \
          "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          row.id, row.fork_id, row.parent_task_id, row.parent_session, row.mode, row.deadline,
          row.members, row.settled_count, row.status, row.result, row.created_at, row.updated_at
        )
      end

      def expectation(fork_id : String) : ::Sebas::Orchestration::Fork::ExpectationRow
        e = expectation?(fork_id)
        raise ::Sebas::Platform::Store::StoreError.new("unknown expectation fork #{fork_id}") if e.nil?
        e
      end

      def expectation?(fork_id : String) : ::Sebas::Orchestration::Fork::ExpectationRow?
        row = @db.query_one?("SELECT id, fork_id, parent_task_id, parent_session, mode, deadline, members, settled_count, status, result, created_at, updated_at FROM expectations WHERE fork_id = ?", fork_id) do |result_set|
          read_expectation(result_set)
        end
        row
      end

      def expectations_by_status(status : String) : Array(::Sebas::Orchestration::Fork::ExpectationRow)
        rows = [] of ::Sebas::Orchestration::Fork::ExpectationRow
        @db.query("SELECT id, fork_id, parent_task_id, parent_session, mode, deadline, members, settled_count, status, result, created_at, updated_at FROM expectations WHERE status = ? ORDER BY created_at", status) do |result_set|
          result_set.each { rows << read_expectation(result_set) }
        end
        rows
      end

      # 状态机迁移（guarded：from 不符即拒绝，防止并发/重复迁移破坏状态机）。
      def transition_expectation(id : String, from : String, to : String,
                                 settled_count : Int32? = nil, result : String? = nil) : Nil
        changed = if settled_count.nil?
                    @db.exec("UPDATE expectations SET status = ?, result = COALESCE(?, result), updated_at = ? " \
                             "WHERE id = ? AND status = ?", to, result, now, id, from).rows_affected
                  else
                    @db.exec("UPDATE expectations SET status = ?, settled_count = ?, result = COALESCE(?, result), updated_at = ? " \
                             "WHERE id = ? AND status = ?", to, settled_count, result, now, id, from).rows_affected
                  end
        raise ::Sebas::Platform::Store::StoreError.new("expectation #{id} 状态迁移失败：期望 from=#{from}，当前非该状态") if changed == 0
      end

      private def read_expectation(rs) : ::Sebas::Orchestration::Fork::ExpectationRow
        ::Sebas::Orchestration::Fork::ExpectationRow.new(
          id: rs.read(String), fork_id: rs.read(String), parent_task_id: rs.read(String),
          parent_session: rs.read(String), mode: rs.read(String), deadline: rs.read(String),
          members: rs.read(String), settled_count: rs.read(Int32), status: rs.read(String),
          result: rs.read(String?), created_at: rs.read(String), updated_at: rs.read(String)
        )
      end
    end
  end
end
