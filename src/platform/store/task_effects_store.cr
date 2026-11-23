# frozen_string_literal: true

# 成员任务副作用持久化（M4.2-WP2）：Store 的 reopen 拆分——沿
# ExpectationStoreMethods 模式，承载 fork 成员 payload 的 effects 读写，
# 缩小大 Store 文件的修改耦合（CodeRabbit 体量拆分建议）。
module Sebas
  module Platform
    module TaskEffectsStoreMethods
      # 成员任务 payload 读取（M4.2-WP2）：join 回写聚合成员副作用清单用
      def task_payload(task_id : String) : String?
        @db.query_one?("SELECT payload FROM tasks WHERE id = ?", task_id) do |reader|
          reader.read(String?)
        end
      end

      # 成员任务 payload 的 effects 合并写（M4.2-WP2）：保留既有键，仅替换
      # effects 数组——ledger 序列化的唯一落库通道。
      def update_task_effects(task_id : String, effects : String) : Nil
        changed = @db.exec("UPDATE tasks SET payload = json_set(payload, '$.effects', json(?)), updated_at = ? WHERE id = ?",
          effects, now, task_id).rows_affected
        raise ::Sebas::Platform::Store::StoreError.new("unknown task #{task_id}") if changed == 0
      end
    end
  end
end
