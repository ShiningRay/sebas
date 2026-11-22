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

        # 回写一条 join.report 到父会话。
        # 返回值三态可区分（CodeRabbit）：:written 实际写入；:duplicate 已写过
        # （幂等跳过）；:non_terminal 非终态拒绝——回写只在四终态时机发生
        # （settled/expired/cancelled），open/settling 写入会把未完成报告
        # 永久占住 memo 闸（之后终态回写被 written? 挡掉）。
        enum WriteResult
          Written
          Duplicate
          NonTerminal
        end

        def write(fork_id : String) : WriteResult
          return WriteResult::Duplicate if written?(fork_id)

          row = @store.expectation(fork_id)
          if {"open", "settling"}.includes?(row.status)
            return WriteResult::NonTerminal
          end
          report = build_report(row)
          @store.append_transcript(row.parent_session, "system", report.to_json)
          @store.memo_put(memo_key(fork_id), row.status)
          WriteResult::Written
        end

        # join.report JSON（semantics §3 草案）：outcome 与状态机终态同名对应；
        # partial 非 outcome 值——不完整信息由 members[].state 终态数组承载。
        def build_report(row : ExpectationRow) : JSON::Any
          member_ids = Array(String).from_json(row.members)
          # any 选定成员：done 中 tasks.updated_at 最早者（先成功，判定器同口径）
          selected = if row.mode == "any"
                       done_ids = member_ids.select { |id| @store.task_status?(id) == "done" }
                       done_ids.min_by? { |id| @store.task_updated_at(id) || "9999" }
                     end
          members = member_ids.map do |task_id|
            session_key = member_session_key(row, task_id)
            lines = @store.transcripts(session_key).size
            raw = @store.task_status?(task_id)
            # 非终态（nil/running/interrupted/pending）统一报告 running——
            # partial 承载只区分「到终态 vs 未到」，不泄露恢复中间态。
            state = %w[done failed cancelled].includes?(raw) ? raw : "running"
            member = {
              "task_id" => JSON::Any.new(task_id),
              "session" => JSON::Any.new(session_key),
              "state"   => JSON::Any.new(state),
              "lines"   => JSON::Any.new(lines.to_i64),
            }
            # any：选定成功结论进 L1（只合并选中者，不复制完整 transcript）；
            # members 数组按声明序，结论取该成员 tasks.result（complete_task 落的）。
            if row.mode == "any" && task_id == selected
              # 只合并选定的先成功成员结论（semantics §4.3 any 行）；不复制完整 transcript
              conclusion = @store.transcripts(session_key).reverse_each
                .find(&.role.==("agent")).try(&.content)
              member["conclusion"] = JSON::Any.new(conclusion.to_s) if conclusion
            end
            JSON::Any.new(member.as(Hash(String, JSON::Any)))
          end
          # M4.1 默认只读档：副作用清单结构先行、恒空数组（M4.2 副作用分级填充）
          effects = [] of JSON::Any
          # outcome 映射：all 模式「状态机 settled 但 result=failed」报告为
          # failed（§4.3 all 行）；allSettled 恒 settled。
          outcome = if row.status == "settled" && row.mode == "all" && row.result == "failed"
                      "failed"
                    else
                      row.status
                    end
          JSON.parse({
            "type"    => "join.report",
            "fork_id" => row.fork_id,
            "mode"    => row.mode,
            "outcome" => outcome,
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
