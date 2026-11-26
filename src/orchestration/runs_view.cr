require "json"
require "../platform/store/store"
require "./ledger"
require "../log"

# runs 查询视图（M2-WP6，design.md §9.2 编排域）：runs.list / runs.get（事件序回放审计）。
# 双入口共用（IPC/HTTP server 挂同一视图）。
module Sebas
  module Orchestration
    class RunsView
      Log = Sebas::Log.for("orchestration.runs")

      def initialize(@store : ::Sebas::Platform::Store::Store, @ledger : Ledger)
      end

      # runs.list：workflow_run intents（id + 状态）
      def list : Array(JSON::Any)
        @store.unfinished_intents.select { |i| i.kind == "workflow_run" }.map do |i|
          JSON::Any.new({"run_id" => JSON::Any.new(i.id), "status" => JSON::Any.new(i.status)})
        end
      end

      # runs.get：run 概要 + ledger 事件序回放（审计口径：按 id 单调重排展示）
      def get(run_id : String) : Hash(String, JSON::Any)?
        intent = @store.intents_with_prefix(run_id).find { |i| i.id == run_id }
        task_status = @store.task_status?(run_id) # run task 可能不存在（intent-only）
        return if intent.nil? && task_status.nil?

        events = @ledger.replay(run_id).map do |row|
          JSON::Any.new({
            "ts" => row.ts, "kind" => row.kind,
            "payload" => row.payload.empty? ? JSON::Any.new("") : begin
              JSON.parse(row.payload)
            rescue ::Exception
              JSON::Any.new(row.payload)
            end,
          }.to_json)
        end
        {
          "run_id"      => JSON::Any.new(run_id),
          "intent"      => JSON::Any.new(intent ? intent.status : "unknown"),
          "task_status" => JSON::Any.new(task_status || "unknown"),
          "events"      => JSON::Any.new(events),
          "event_count" => JSON::Any.new(events.size.to_i64),
        } of String => JSON::Any
      end
    end
  end
end
