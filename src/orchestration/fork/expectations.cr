# frozen_string_literal: true

require "json"
require "time"

module Sebas
  module Orchestration
    module Fork
      # join 汇聚点（M4.1-WP2，Q2 裁断）：expectations 落库 + 回写状态机 + mode 判定器。
      #
      # 语义权威 = docs/design/proposals/fork-join-semantics.md §4：
      #   状态机 open → settling → settled；旁路 open → cancelled（显式取消）、
      #   open → expired（deadline 到，仍走回写器产出 partial 报告）。
      #   成员终态不在本表冗余——tasks.status 是权威，判定器读 tasks 聚合。
      # 崩溃恢复：重启扫描 open|settling 续判；状态机迁移 guarded（from 不符拒绝），
      # 已 settled 的行恢复扫描时跳过——「不重复回写」由幂等的 settle 判定承载。
      class Expectations
        MODES = %w[all any allSettled]

        # 成员终态集：tasks.status 权威值；running/interrupted/pending 未到终态。
        TERMINAL_STATES = %w[done failed cancelled]

        getter store : ::Sebas::Platform::Store::Store

        def initialize(@store : ::Sebas::Platform::Store::Store)
        end

        # fork 声明即登记（fork 原语执行时调用；M4.1-WP3 接线）。
        def create(fork_id : String, parent_task_id : String, parent_session : String,
                   mode : String, members : Array(String), deadline : Time) : ExpectationRow
          unless MODES.includes?(mode)
            raise ::Sebas::Platform::Store::StoreError.new("非法 join mode：#{mode.inspect}（允许 all/any/allSettled）")
          end
          raise ::Sebas::Platform::Store::StoreError.new("fork #{fork_id} 已有 expectation（fork 级唯一）") if @store.expectation?(fork_id)

          now = ::Time.utc.to_rfc3339
          row = ExpectationRow.new(
            id: "join:#{fork_id}", fork_id: fork_id, parent_task_id: parent_task_id,
            parent_session: parent_session, mode: mode, deadline: deadline.to_rfc3339,
            members: members.to_json, settled_count: 0, status: "open",
            result: nil, created_at: now, updated_at: now
          )
          @store.insert_expectation(row)
          row
        end

        # 显式取消（用户/父会话）：仅 open 可旁路。
        def cancel(fork_id : String) : Nil
          @store.transition_expectation("join:#{fork_id}", "open", "cancelled")
        end

        # 判定器：读成员终态聚合（tasks 权威），按 mode 落状态机迁移。
        # 返回迁移后的行；未到 settle 条件时原样返回（open）。
        def judge(fork_id : String, now : ::Time = ::Time.utc) : ExpectationRow
          row = @store.expectation(fork_id)
          return row unless {"open", "settling"}.includes?(row.status)

          member_ids = Array(String).from_json(row.members)
          statuses = member_ids.map do |id|
            status = @store.task_status?(id)
            raise ::Sebas::Platform::Store::StoreError.new("expectation 成员任务缺失：#{id}") if status.nil?
            status
          end
          terminal = statuses.select { |status| TERMINAL_STATES.includes?(status) }
          settled_count = terminal.size
          all_terminal = settled_count == member_ids.size
          any_done = statuses.includes?("done")

          case row.mode
          when "any"
            # any 只认成功终态；失败不计数。全部失败 + deadline 到期 → expired（§4.3 any 行）。
            if any_done
              settle(row, settled_count, "settled", result: first_done_summary(member_ids))
            elsif deadline_passed?(row.deadline, now)
              expire_row(row, now, settled_count)
              @store.expectation(row.fork_id)
            else
              row
            end
          when "all"
            # 全部到位才判（不短路：副作用已发生，等待比中途取消更可预期）；
            # 有失败 → settled(result=failed)，成功成员结论照供父（§4.3 all 行）。
            if all_terminal
              outcome = statuses.all? { |status| status == "done" } ? "settled" : "failed"
              settle(row, settled_count, "settled", result: outcome)
            elsif deadline_passed?(row.deadline, now)
              expire_row(row, now, settled_count)
              @store.expectation(row.fork_id)
            else
              row
            end
          else # allSettled
            # 失败也算完成：全部终态即 settled（§4.3 allSettled 行）。
            if all_terminal
              settle(row, settled_count, "settled", result: "settled")
            elsif deadline_passed?(row.deadline, now)
              expire_row(row, now, settled_count)
              @store.expectation(row.fork_id)
            else
              row
            end
          end
        end

        # deadline 到期：open → expired（partial 回写由 JoinWriter 承载，WP4）。
        def expire(fork_id : String, now : ::Time = ::Time.utc) : Nil
          expire_row(@store.expectation(fork_id), now)
        end

        private def expire_row(row : ExpectationRow, now : ::Time, settled_count : Int32? = nil) : Nil
          terminal = settled_count || Array(String).from_json(row.members).count do |id|
            TERMINAL_STATES.includes?(@store.task_status?(id))
          end
          @store.transition_expectation(row.id, "open", "expired", settled_count: terminal,
            result: "deadline exceeded at #{now.to_rfc3339}")
        end

        # 崩溃恢复：重启扫描 open|settling 续判。已 settled/cancelled/expired 的行
        # 不再动——状态机迁移 guarded，重复恢复不产生第二次迁移/回写。
        def recover(now : ::Time = ::Time.utc) : Int32
          judged = 0
          (@store.expectations_by_status("open") + @store.expectations_by_status("settling")).each do |row|
            after = judge(row.fork_id, now)
            judged += 1 if after.status != row.status
          end
          judged
        end

        private def settle(row : ExpectationRow, settled_count : Int32, status : String, result : String) : ExpectationRow
          # settling 起点 = 两步迁移间崩溃的恢复路径（open→settling 已提交）：
          # 不重放第一步，直接完成收尾（guarded from=settling）。
          @store.transition_expectation(row.id, "open", "settling") if row.status == "open"
          @store.transition_expectation(row.id, "settling", status, settled_count: settled_count, result: result)
          @store.expectation(row.fork_id)
        end

        # any 的 result 必须指向**最先进入成功终态**的成员（semantics §2.3/§4.3）：
        # tasks.status 无成功先后信息，tasks.updated_at（状态迁移时刻戳）是唯一
        # 可持久化恢复的先后证据——取 done 成员中 updated_at 最早者。
        private def first_done_summary(member_ids : Array(String)) : String
          done = member_ids.select { |id| @store.task_status?(id) == "done" }
          raise ::Sebas::Platform::Store::StoreError.new("any 判定失败：无 done 成员") if done.empty?
          first = done.min_by { |id| @store.task_updated_at(id) || "9999" }
          "first success: #{first}"
        end

        private def deadline_passed?(deadline : String, now : ::Time) : Bool
          ::Time.parse_rfc3339(deadline) <= now
        rescue e
          raise ::Sebas::Platform::Store::StoreError.new("expectation deadline 非法（#{deadline}）：#{e.message}")
        end
      end

      # expectations 行（与 store EXPECTATION_COLUMNS 一一对应）。
      record ExpectationRow,
        id : String, fork_id : String, parent_task_id : String, parent_session : String,
        mode : String, deadline : String, members : String, settled_count : Int32,
        status : String, result : String?, created_at : String, updated_at : String
    end
  end
end
