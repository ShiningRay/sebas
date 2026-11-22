# frozen_string_literal: true

require "json"

module Sebas
  module Orchestration
    module Fork
      # join 三层回写（M4.1-WP4）+ 四时机语义：
      #
      # L1 主上下文：结构化 join.report 进父会话 append_transcript（下一 turn
      #    transcripts 窗口自动带入）——结论 + 成员终态数组 + 副作用清单；
      # L2 全量落盘：分身 transcript 在执行期已 SQLite+JSONL 双写（store 双写），
      #    回写消息引用成员会话键与行数范围，不搬运；
      # L3 可检索索引：成员（task_id、会话键、终态、行数）三元组在 L1 JSON 内。
      #
      # 四时机：正常 settled / 超时 expired（partial 标注）/ 失败（all 全成员
      # 终态落 result=failed）/ 取消 cancelled——M4.1 默认只读档副作用清单恒空，
      # 结构先行（M4.2 副作用分级落地后填充）。
      #
      # 幂等：memo 键 join:<fork_id>:written 先查后写（memo_put FWW 先例
      # store.cr:369-383）——崩溃重放不重复回写。
      class JoinWriter
        getter store : ::Sebas::Platform::Store::Store

        def initialize(@store : ::Sebas::Platform::Store::Store)
        end

        # 回写幂等 memo 键：fork 级标识（不含成员序号）——同次 fork 一条
        # 回写记录，全成员共用同一幂等闸。
        def memo_key(fork_id : String) : String
          "join:#{fork_id}:written"
        end

        # 已回写过？（memo 决策先例：memo_get 非 nil 即已写）
        def written?(fork_id : String) : Bool
          !@store.memo_get(memo_key(fork_id)).nil?
        end

        # 回写一条 join.report 到父会话（幂等：已写过直接返回 false 不重复落）。
        # 返回是否实际写入。
        def write(fork_id : String) : Bool
          return false if written?(fork_id)

          row = @store.expectation(fork_id)
          report = build_report(row)
          @store.append_transcript(row.parent_session, "system", report.to_json)
          @store.memo_put(memo_key(fork_id), row.status)
          true
        end

        # join.report JSON（semantics §3 草案）：outcome 与状态机终态同名对应；
        # partial 非 outcome 值——不完整信息由 members[].state 终态数组承载。
        def build_report(row : ExpectationRow) : JSON::Any
          member_ids = Array(String).from_json(row.members)
          members = member_ids.map do |task_id|
            session_key = member_session_key(row, task_id)
            lines = @store.transcripts(session_key).size
            JSON::Any.new({
              "task_id" => JSON::Any.new(task_id),
              "session" => JSON::Any.new(session_key),
              "state"   => JSON::Any.new(@store.task_status?(task_id) || "running"),
              "lines"   => JSON::Any.new(lines.to_i64),
            }.as(Hash(String, JSON::Any)))
          end
          # M4.1 默认只读档：副作用清单结构先行、恒空数组（M4.2 副作用分级填充）
          effects = [] of JSON::Any
          JSON.parse({
            "type"    => "join.report",
            "fork_id" => row.fork_id,
            "mode"    => row.mode,
            "outcome" => row.status,
            "result"  => row.result.to_s,
            "effects" => effects,
            "members" => members,
          }.to_json)
        end

        # 成员会话键：与 Executor 派生同构——父 agent 段取自 parent_session
        # 五段键首段（分身以父人格运行，agent 段 = 父 agent_id，semantics §1.3）。
        # task_id 形如 fork:<短码>:<序号>，peer 段 = fork_id:member_index 与
        # Executor 的 member_peer 一致。
        private def member_session_key(row : ExpectationRow, task_id : String) : String
          parent_agent_id = row.parent_session.split(":")[1]? || "unknown"
          member_index = task_id.split(":").last
          ::Sebas::Agents.session_key(parent_agent_id, "internal", "fork",
            "#{row.fork_id}:#{member_index}")
        end
      end
    end
  end
end
