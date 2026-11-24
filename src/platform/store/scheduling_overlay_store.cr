# frozen_string_literal: true

# 调度参数 overlay 持久化（M4.5-WP6）：scope 级 patch（gateway/agent:<name>），
# revision 全局单调递增（expected_revision 防并发覆盖）；operator/updated_at
# 即审计记录。DDL 在 store.cr SCHEMA，本文件只承载读写方法。
module Sebas
  module Platform
    module SchedulingOverlayStoreMethods
      record SchedulingOverlayRow, scope : String, patch_yaml : String, revision : Int64,
        operator : String, updated_at : String

      # 全局当前 revision（单例 meta 行持久——不随 reset 回退，单调约定 gzjj）
      def scheduling_revision : Int64
        @db.query_one?(
          "SELECT revision FROM scheduling_meta WHERE id = 1", as: Int64
        ) || 0_i64
      end

      def scheduling_overlays : Array(SchedulingOverlayRow)
        rows = [] of SchedulingOverlayRow
        @db.query("SELECT scope, patch_yaml, revision, operator, updated_at " \
                  "FROM scheduling_overlays ORDER BY scope") do |result_set|
          result_set.each do
            rows << SchedulingOverlayRow.new(result_set.read(String), result_set.read(String),
              result_set.read(Int64), result_set.read(String), result_set.read(String))
          end
        end
        rows
      end

      def scheduling_overlay(scope : String) : SchedulingOverlayRow?
        @db.query_one?(
          "SELECT scope, patch_yaml, revision, operator, updated_at " \
          "FROM scheduling_overlays WHERE scope = ?", scope
        ) do |result_set|
          SchedulingOverlayRow.new(result_set.read(String), result_set.read(String),
            result_set.read(Int64), result_set.read(String), result_set.read(String))
        end
      end

      # upsert：revision 事务内全局自增（单例 meta 持久，reset 不回退——gzjj）
      def upsert_scheduling_overlay(scope : String, patch_yaml : String, operator : String) : Int64
        revision = 0_i64
        @db.transaction do |tx|
          revision = bump_scheduling_revision(tx)
          tx.connection.exec(
            "INSERT INTO scheduling_overlays (scope, patch_yaml, revision, operator, updated_at) " \
            "VALUES (?, ?, ?, ?, ?) ON CONFLICT(scope) DO UPDATE SET " \
            "patch_yaml = excluded.patch_yaml, revision = excluded.revision, " \
            "operator = excluded.operator, updated_at = excluded.updated_at",
            scope, patch_yaml, revision, operator, now
          )
        end
        revision
      end

      # reset：删除 scope overlay（恢复上一层继承）+ 事务内推进版本（不回退）；
      # 返回是否删除
      def delete_scheduling_overlay(scope : String) : Bool
        deleted = false
        @db.transaction do |tx|
          bump_scheduling_revision(tx)
          deleted = tx.connection.exec(
            "DELETE FROM scheduling_overlays WHERE scope = ?", scope
          ).rows_affected > 0
        end
        deleted
      end

      private def bump_scheduling_revision(tx : ::DB::Transaction) : Int64
        tx.connection.exec(
          "INSERT INTO scheduling_meta (id, revision) VALUES (1, 1) " \
          "ON CONFLICT(id) DO UPDATE SET revision = revision + 1"
        )
        tx.connection.scalar("SELECT revision FROM scheduling_meta WHERE id = 1").as(Int64)
      end
    end
  end
end
