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
          "INSERT INTO expectations (id, members_final, fork_id, parent_task_id, parent_session, mode, deadline, members, settled_count, status, result, created_at, updated_at) " \
          "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          row.id, row.members_final, row.fork_id, row.parent_task_id, row.parent_session, row.mode, row.deadline,
          row.members, row.settled_count, row.status, row.result, row.created_at, row.updated_at
        )
      end

      def expectation(fork_id : String) : ::Sebas::Orchestration::Fork::ExpectationRow
        e = expectation?(fork_id)
        raise ::Sebas::Platform::Store::StoreError.new("unknown expectation fork #{fork_id}") if e.nil?
        e
      end

      def expectation?(fork_id : String) : ::Sebas::Orchestration::Fork::ExpectationRow?
        row = @db.query_one?("SELECT id, members_final, fork_id, parent_task_id, parent_session, mode, deadline, members, settled_count, status, result, created_at, updated_at FROM expectations WHERE fork_id = ?", fork_id) do |result_set|
          read_expectation(result_set)
        end
        row
      end

      def expectations_by_status(status : String) : Array(::Sebas::Orchestration::Fork::ExpectationRow)
        rows = [] of ::Sebas::Orchestration::Fork::ExpectationRow
        @db.query("SELECT id, members_final, fork_id, parent_task_id, parent_session, mode, deadline, members, settled_count, status, result, created_at, updated_at FROM expectations WHERE status = ? ORDER BY created_at", status) do |result_set|
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

      # fork 派发期逐成员补全 members 列表（只允许 open 行；已落定行不得改，
      # CodeRabbit：按 id 过滤的 UPDATE 会污染终态行）。
      def expectations_append_member(id : String, task_id : String) : Nil
        row = expectation_by_id(id)
        raise ::Sebas::Platform::Store::StoreError.new(
          "expectation #{id} 非 open，不得追加成员（当前 #{row.status}）") unless row.status == "open"
        members = Array(String).from_json(row.members)
        return if members.includes?(task_id)
        @db.exec("UPDATE expectations SET members = ?, updated_at = ? WHERE id = ? AND status = 'open'",
          (members + [task_id]).to_json, now, id)
      end

      # 派发完成标记：members 已含全部声明成员后置 members_final=1。
      # judge/recover 只处理 final=1 的行——派发未完成的 expectation 不得落定
      # （CodeRabbit：中途崩溃恢复会把不完整集合判成部分完成）。
      # 派发开始：final 0→1 翻转用（executor 预登记后置 0；派发完 mark 置回 1）。
      def expectations_unmark_dispensed(id : String) : Nil
        @db.exec("UPDATE expectations SET members_final = 0, updated_at = ? WHERE id = ?", now, id)
      end

      def expectations_mark_dispensed(id : String) : Nil
        changed = @db.exec("UPDATE expectations SET members_final = 1, updated_at = ? WHERE id = ? AND status = 'open'", now, id).rows_affected
        raise ::Sebas::Platform::Store::StoreError.new("expectation #{id} 标记派发完成失败：非 open 行") if changed == 0
      end

      def expectation_by_id(id : String) : ::Sebas::Orchestration::Fork::ExpectationRow
        row = @db.query_one?("SELECT id, members_final, fork_id, parent_task_id, parent_session, mode, deadline, members, settled_count, status, result, created_at, updated_at FROM expectations WHERE id = ?", id) do |result_set|
          read_expectation(result_set)
        end
        raise ::Sebas::Platform::Store::StoreError.new("unknown expectation #{id}") if row.nil?
        row
      end

      private def read_expectation(rs) : ::Sebas::Orchestration::Fork::ExpectationRow
        ::Sebas::Orchestration::Fork::ExpectationRow.new(
          id: rs.read(String), members_final: rs.read(Int64).to_i32, fork_id: rs.read(String), parent_task_id: rs.read(String),
          parent_session: rs.read(String), mode: rs.read(String), deadline: rs.read(String),
          members: rs.read(String), settled_count: rs.read(Int64).to_i32, status: rs.read(String),
          result: rs.read(String?), created_at: rs.read(String), updated_at: rs.read(String)
        )
      end
    end
  end
end
