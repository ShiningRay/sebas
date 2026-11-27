# frozen_string_literal: true

# 逐租约动作与 scope 冲突预算（M4x-Parallel-WP3，#221；Proposal §4.1、§6.1、§7.1）。
#
# 这两块是并行的实际门槛：多租约下「等 CI 的那张不能拖住另一张」，
# scope 重叠的候选不能同时认领。全部是纯函数判定，不触网。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class LeaseActionsTest < Minitest::Test
  include SnapshotHelpers

  def in_progress_issue(number, scope: ["src/"], labels: [], **rest)
    issue(number, body: automation(scope: scope), status: "In progress", labels: labels, **rest)
  end

  # files 默认给一个落在测试 scope 内的值：越界检测（F14）在无 file 清单时
  # 按不可判定处理，缺省会把这些用例全部变成 needs_human，测不到原本的判定。
  # 默认 files 落在 src/ 下：本文件用例的 scope 都是 src/ 或它的子目录。
  # 越界检测（F14）生效后，给错目录的文件会让判定变成 needs_human，
  # 于是测不到原本要测的分支。
  def open_pr(number:, issue:, state: "CLEAN", branches: nil, threads: [], checks: nil,
    base: "main", files: [{"filename" => "src/store/x.cr"}])
    {
      "number" => number,
      "head_ref_name" => branches || "feat/#{issue}",
      "base_ref_name" => base,
      "state" => "OPEN",
      "merge_state_status" => state,
      "checks" => checks,
      "closing_issues" => Array(issue),
      "review_threads" => threads,
      "files" => files
    }
  end

  # --- 逐租约动作（§4.1）---

  # 一张在等 CI、另一张可推进：等的那张不占用本机动作位。
  def test_waiting_lease_does_not_block_actionable_lease
    data = snapshot(
      issues: [
        in_progress_issue(1, scope: ["src/store/"]),
        in_progress_issue(2, scope: ["src/keys/"])
      ],
      capacity: 2,
      pull_requests: [
        open_pr(number: 50, issue: 1, state: "BLOCKED",
          checks: [{"name" => "spec / ubuntu-latest", "status" => "IN_PROGRESS", "conclusion" => nil}]),
        open_pr(number: 51, issue: 2, state: "BEHIND", checks: [],
          files: [{"filename" => "src/keys/y.cr"}])
      ]
    )
    view = plan(data, records: [
      {"issue" => 1, "phase" => "claimed", "branch" => "feat/1", "pr" => 50},
      {"issue" => 2, "phase" => "claimed", "branch" => "feat/2", "pr" => 51}
    ])
    # BEHIND 现在归合并队列的 update_branch 步骤处理（§3），不再是 resume_pr。
    assert_equal "merge_ready", view.next_action
    assert_equal 2, view.next_issue
    # 逐租约表两张都在，判定互不影响
    by_issue = view.leases.to_h { |lease| [lease.issue, lease] }
    assert_equal "wait", by_issue[1].action
    assert_equal "merge_ready", by_issue[2].action, "BEHIND 进队列由 update_branch 处理"
    assert_operator by_issue[1].action, :!=, "invalid_plan"
  end

  # merge_ready 优先于 resume_pr：CLEAN 的 PR 先进合并队列。
  def test_clean_pr_reports_merge_ready
    data = snapshot(
      issues: [in_progress_issue(1, scope: ["src/"])],
      capacity: 2,
      pull_requests: [open_pr(number: 50, issue: 1, state: "CLEAN", checks: [])]
    )
    action = select(data, record: {"issue" => 1, "phase" => "claimed", "branch" => "feat/1", "pr" => 50})
    assert_equal "merge_ready", action.action
    assert_includes action.reason, "合并队列"
    # 进队列不等于放行：reason 必须仍点出前提
    assert_includes action.reason, "verify merge --pre"
  end

  # 一个 PR 关联多张卡：归属不清，fail-closed。
  def test_pr_with_multiple_closing_issues_is_invalid
    data = snapshot(
      issues: [in_progress_issue(1, scope: ["src/"]), in_progress_issue(2, scope: ["docs/"])],
      capacity: 2,
      pull_requests: [open_pr(number: 50, issue: [1, 2], checks: [])]
    )
    view = plan(data, records: [{"issue" => 1, "phase" => "claimed", "branch" => "feat/1"}])
    assert_equal "invalid_plan", view.next_action
    assert_includes view.invalid_reason, "一个 PR 只允许关联一张卡"
  end

  # 目标分支不是 main：拒绝（§7.2 三次核对的第一处）。
  def test_pr_targeting_other_base_is_invalid
    data = snapshot(
      issues: [in_progress_issue(1, scope: ["src/"])],
      capacity: 2,
      pull_requests: [open_pr(number: 50, issue: 1, checks: [], base: "release/0.2")]
    )
    action = select(data, record: {"issue" => 1, "phase" => "claimed", "branch" => "feat/1"})
    assert_equal "invalid_plan", action.action
    assert_includes action.reason, "只允许 main"
  end

  # PR 分支与租约分支不一致：续做会写错分支。
  def test_pr_branch_mismatch_is_invalid
    data = snapshot(
      issues: [in_progress_issue(1, scope: ["src/"])],
      capacity: 2,
      pull_requests: [open_pr(number: 50, issue: 1, checks: [], branches: "feat/999")]
    )
    action = select(data, record: {"issue" => 1, "phase" => "claimed", "branch" => "feat/1"})
    assert_equal "invalid_plan", action.action
    assert_includes action.reason, "与租约分支"
  end

  # needs:human 只作用于本卡：另一张仍可推进。
  def test_needs_human_on_one_lease_does_not_stop_others
    data = snapshot(
      issues: [
        in_progress_issue(1, scope: ["src/store/"], labels: ["needs:human"]),
        in_progress_issue(2, scope: ["src/keys/"])
      ],
      capacity: 2,
      pull_requests: [
        open_pr(number: 51, issue: 2, state: "BEHIND", checks: [],
          files: [{"filename" => "src/keys/y.cr"}])
      ]
    )
    view = plan(data, records: [
      {"issue" => 1, "phase" => "paused", "branch" => "feat/1"},
      {"issue" => 2, "phase" => "claimed", "branch" => "feat/2", "pr" => 51}
    ])
    assert_equal "merge_ready", view.next_action, "BEHIND 进队列由 update_branch 处理"
    assert_equal 2, view.next_issue
    by_issue = view.leases.to_h { |lease| [lease.issue, lease] }
    assert_equal "needs_human", by_issue[1].action
  end

  # 本机持有的一张 wait、容量还有空位：允许补位认领（§7.1「等待不占算力」）。
  def test_waiting_lease_frees_slot_for_new_card
    data = snapshot(
      issues: [
        in_progress_issue(1, scope: ["src/store/"]),
        issue(2, body: automation(order: [4, 2], scope: ["src/keys/"]))
      ],
      capacity: 2,
      pull_requests: [
        open_pr(number: 50, issue: 1, state: "BLOCKED",
          checks: [{"name" => "spec / ubuntu-latest", "status" => "IN_PROGRESS", "conclusion" => nil}])
      ]
    )
    action = select(data, record: {"issue" => 1, "phase" => "claimed", "branch" => "feat/1", "pr" => 50})
    assert_equal "claim_issue", action.action
    assert_equal 2, action.issue
  end

  # --- scope 冲突预算（§6.1 / Q4=A 强制）---

  def test_scope_prefix_containment_conflicts
    data = snapshot(
      issues: [
        in_progress_issue(1, scope: ["src/"]),
        issue(2, body: automation(order: [4, 2], scope: ["src/bus/"]))
      ],
      capacity: 2
    )
    action = select(data)
    assert_equal "blocked", action.action
    row = action.excluded.find { |item| item["issue"] == 2 }
    assert_includes row["reason"], "重叠"
  end

  def test_candidate_without_scope_cannot_parallelize
    data = snapshot(
      issues: [
        in_progress_issue(1, scope: ["src/"]),
        issue(2, body: automation(order: [4, 2]))
      ],
      capacity: 2
    )
    action = select(data)
    assert_equal "blocked", action.action
    row = action.excluded.find { |item| item["issue"] == 2 }
    assert_includes row["reason"], "缺 scope"
  end

  # 共享文件（CHANGELOG、schema.cr）靠写进 scope 进入预算：
  # 两张卡都声明同一文件即冲突，于是不会并行。
  def test_shared_file_declared_in_both_scopes_conflicts
    data = snapshot(
      issues: [
        in_progress_issue(1, scope: ["CHANGELOG.md"]),
        issue(2, body: automation(order: [4, 2], scope: ["src/bus/", "CHANGELOG.md"]))
      ],
      capacity: 2
    )
    action = select(data)
    assert_equal "blocked", action.action
  end

  # 容量 1 + 无在途租约：scope 过滤恒为空集，行为与单卡一致。
  def test_single_capacity_ignores_scope_budget
    data = snapshot(issues: [issue(1, body: automation(scope: ["src/"]))])
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 1, action.issue
  end

  # 在途卡 scope 声明非法：按未声明处理（独占容量），不静默当成不冲突。
  def test_invalid_active_scope_is_treated_as_undeclared
    the_issue = in_progress_issue(1)
    the_issue["body"] = automation(scope: ["../escape"])
    data = snapshot(
      issues: [the_issue, issue(2, body: automation(order: [4, 2], scope: ["src/bus/"]))],
      capacity: 2
    )
    action = select(data)
    assert_equal "blocked", action.action
    row = action.excluded.find { |item| item["issue"] == 2 }
    assert_includes row["reason"], "未声明 scope"
  end
end
