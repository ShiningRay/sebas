# frozen_string_literal: true

require "json"
require "digest"

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
          # 报告行 + memo 同一 SQLite 事务原子提交（CodeRabbit）：任一步失败
          # 整体回滚，重放不会出现「有报告无 memo」导致的第二份 join.report。
          @store.write_join_report(row.parent_session, report.to_json,
            memo_key(fork_id), row.status)
          WriteResult::Written
        end

        # join.report JSON（semantics §3 草案）：outcome 与状态机终态同名对应；
        # partial 非 outcome 值——不完整信息由 members[].state 终态数组承载。
        def build_report(row : ExpectationRow) : JSON::Any
          member_ids = Array(String).from_json(row.members)
          # any 获胜成员：读判定时持久化的 row.result（"first success: <task_id>"）——
          # 回写与判定同一成员，不按 updated_at 重选（同秒并列可能漂移，CodeRabbit）
          selected = if row.mode == "any" && row.result.to_s.starts_with?("first success: ")
                       row.result.to_s.lchop("first success: ")
                     end
          members = build_members(row, member_ids, selected)
          effects, write_chains = collect_member_effects(member_ids)
          declared, fork_baseline = fork_file_baseline(row.fork_id)
          conflicts = detect_conflicts(write_chains, declared, fork_baseline)
          # outcome 映射：all 模式「状态机 settled 但 result=failed」报告为
          # failed（§4.3 all 行）；allSettled 恒 settled。
          outcome = if row.status == "settled" && row.mode == "all" && row.result == "failed"
                      "failed"
                    else
                      row.status
                    end
          JSON.parse({
            "type"      => "join.report",
            "fork_id"   => row.fork_id,
            "mode"      => row.mode,
            "outcome"   => outcome,
            "result"    => row.result.to_s,
            "effects"   => effects,
            "conflicts" => conflicts,
            "members"   => members,
          }.to_json)
        end

        # 成员三元组数组（M4.1-WP4）：task_id/会话键/终态/行数 + any 选中者结论
        private def build_members(row : ExpectationRow, member_ids : Array(String),
                                  selected : String?) : Array(JSON::Any)
          member_ids.map do |task_id|
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
            if row.mode == "any" && row.status != "cancelled" && task_id == selected
              # 只合并选定的先成功成员结论（semantics §4.3 any 行）；不复制完整 transcript
              conclusion = @store.transcripts(session_key).reverse_each
                .find(&.role.==("agent")).try(&.content)
              member["conclusion"] = JSON::Any.new(conclusion.to_s) if conclusion
            end
            JSON::Any.new(member.as(Hash(String, JSON::Any)))
          end
        end

        # 副作用清单聚合（M4.2-WP2 §2.2 通则 1「副作用已发生不隐瞒」）：各成员
        # payload 的 effects 数组（成员 ledger 落库），保持发生序；同时提取文件
        # 写后摘要——冲突检测基线 = 成员写后状态（成员自己的合法写入不算冲突，
        # 父在其后的改动才算，§2.2 L1）。
        private def collect_member_effects(member_ids : Array(String)) : Tuple(Array(JSON::Any), Hash(String, Array(Tuple(String, String))))
          effects = member_ids.flat_map do |task_id|
            raw = @store.task_payload(task_id)
            next [] of JSON::Any unless raw
            data = JSON.parse(raw).as_h?
            next [] of JSON::Any unless data
            # 缺失或 null（升级前持久化的成员 payload 无 effects 键）视为空数组
            raw_effects = data["effects"]?
            effects_array = raw_effects.try(&.as_a?)
            next [] of JSON::Any unless effects_array
            effects_array
          end
          sorted = effects.sort_by(&.as_h.[]("at").as_s)
          write_chains = Hash(String, Array(Tuple(String, String))).new
          sorted.each do |effect|
            next unless effect.as_h["side_effect"].as_s == "file_write"
            target = effect.as_h["target"].as_s
            chain = write_chains[target] ||= Array(Tuple(String, String)).new
            chain << {effect.as_h["pre_digest"].as_s, effect.as_h["post_digest"].as_s}
          end
          {sorted, write_chains}
        end

        # 指纹对比（M4.2-WP2）按写入链逐环检测：fork 基线 vs 首写 pre（父在
        # 首写前动过）、链内前环 post vs 后环 pre（父在两次写之间动过）、尾环
        # post vs 回写时现状（父在最后写后动过）。命中任一环即 CONFLICT，
        # 只报告不合并（矩阵通则 2）。files 未声明的 fork 无基线可比，跳过
        # pre/fork 对比（区分「fork 时不存在」与「无基线」两态）。
        private def detect_conflicts(write_chains : Hash(String, Array(Tuple(String, String))),
                                     files_declared : Bool, fork_baseline : Hash(String, JSON::Any)) : Array(JSON::Any)
          return [] of JSON::Any if write_chains.empty?
          write_chains.compact_map do |path, chain|
            next if chain.empty?
            drifted = false
            if files_declared
              fork_digest = fork_baseline[path]?.try(&.as_s)
              first_pre, _ = chain.first
              # fork 时不存在（无基线记录）→ 写前非 deleted 即父建过
              drifted ||= fork_digest ? first_pre != fork_digest : first_pre != "deleted"
              chain.each_with_index do |(pre, _), i|
                next if i.zero?
                prev_post = chain[i - 1][1]
                drifted ||= pre != prev_post # 链内断点 = 父在两次写之间动过
              end
            end
            _, last_post = chain.last
            drifted ||= current_digest(path) != last_post # 父在最后写后动过
            next unless drifted
            JSON::Any.new({
              "path"     => JSON::Any.new(path),
              "status"   => JSON::Any.new("CONFLICT"),
              "baseline" => JSON::Any.new(chain.first[1]),
              "current"  => JSON::Any.new(current_digest(path)),
            }.as(Hash(String, JSON::Any)))
          end
        end

        # fork 时点的工作区基线（run 开始记的 memo 快照）：{declared, digests}。
        # 无 memo = 未声明 files（declared=false，无基线可比）；有 memo 但
        # digests 空 = 声明了且 fork 时全不存在（declared=true 仍可判父建过）。
        private def fork_file_baseline(fork_id : String) : Tuple(Bool, Hash(String, JSON::Any))
          raw = @store.memo_get("fork:#{fork_id}:files")
          return {false, Hash(String, JSON::Any).new} unless raw
          parsed = JSON.parse(raw).as_h
          {parsed["declared"]?.try(&.as_bool) || false, parsed["digests"]?.try(&.as_h) || Hash(String, JSON::Any).new}
        end

        # 现状摘要：存在性检查后可能被并发删除（CodeRabbit）——读取期 NotFound
        # 与存在性否等价处理为 "deleted"；其他读取错误如实上抛（不冒充删除）。
        private def current_digest(path : String) : String
          return "deleted" unless File.file?(path)
          ::Digest::SHA256.hexdigest(File.read(path))
        rescue File::NotFoundError
          "deleted"
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
