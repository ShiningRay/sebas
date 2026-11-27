# frozen_string_literal: true

# 选卡缺陷回归（阻断 8/9/10、应修 3/4/5/6）：暂停卡、在途 PR、milestone 归一。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class PolicyRegressionTest < Minitest::Test
  include SnapshotHelpers

  # 阻断 8：暂停恢复不应依赖 in-progress 标签
  def test_resume_paused_card_without_claim_label
    data = snapshot(issues: [
      issue(1, body: automation, labels: %w[needs:human agent:resume]),
      issue(2, body: automation(order: [4, 2]))
    ])
    action = select(data)
    assert_equal "resume_issue", action.action
    assert_equal 1, action.issue
  end

  # 阻断 9：needs:human + CLEAN PR 不得推进合并
  def test_needs_human_with_clean_pr_waits
    pr = {
      "number" => 9, "state" => "OPEN", "merge_state_status" => "CLEAN",
      "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}],
      "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(
      issues: [issue(1, body: automation, labels: ["needs:human"], status: "In progress")],
      pull_requests: [pr]
    )
    action = select(data, record: {"issue" => 1, "pr" => 9})
    assert_equal "needs_human", action.action
    refute_includes action.reason, "squash"
  end

  # 未建 PR 的暂停也必须报 needs_human，不能去开别的卡
  def test_paused_card_without_claim_blocks_new_work
    data = snapshot(issues: [
      issue(1, body: automation, labels: ["needs:human"]),
      issue(2, body: automation(order: [4, 2]))
    ])
    action = select(data)
    assert_equal "needs_human", action.action
    assert_equal 1, action.issue
  end

  # 阻断 10：已有 open PR 的卡不得重复认领
  def test_card_with_open_pr_is_excluded_from_selection
    pr = {"number" => 9, "state" => "OPEN", "closing_issues" => [1], "checks" => [], "review_threads" => []}
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1])),
      issue(2, body: automation(order: [4, 2]))
    ], pull_requests: [pr])
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 2, action.issue
    assert(action.excluded.any? { |item| item["issue"] == 1 })
  end

  # 应修 3：非法 milestone state
  def test_invalid_milestone_state_is_rejected
    data = snapshot(issues: [], milestones: [
      {"number" => 2, "title" => "M", "state" => "paused", "open_issues" => 1, "description" => "order: 4\ntrack: main\n"}
    ])
    error = assert_raises(SebasAgents::InvalidPlan) { select(data) }
    assert_includes error.message, "state"
  end

  # 应修 5：order "4" 与 "04" 重复
  def test_order_with_leading_zero_is_duplicate
    data = snapshot(issues: [], milestones: [
      milestone(number: 2, order: "4", track: "main", open_issues: 1),
      {"number" => 3, "title" => "M", "state" => "open", "open_issues" => 1, "description" => "order: 04\ntrack: main\n"}
    ])
    error = assert_raises(SebasAgents::InvalidPlan) { select(data) }
    assert_includes error.message, "重复"
  end

  # 应修 6：open_issues 缓存为 0 但仍有 open 卡
  def test_stale_open_issues_does_not_cause_handoff
    data = snapshot(
      issues: [issue(1, body: automation)],
      milestones: [milestone(number: 2, order: "4", track: "main", open_issues: 0)]
    )
    action = select(data)
    assert_equal "claim_issue", action.action
  end

  # 应修 4：milestone 类型归一化
  def test_string_milestone_matches
    data = snapshot(
      issues: [issue(1, body: automation).merge("milestone" => "2")],
      milestones: [milestone(number: 2, order: "4", track: "main", open_issues: 1)]
    )
    assert_equal "claim_issue", select(data).action
  end
end
