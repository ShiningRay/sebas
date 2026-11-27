# frozen_string_literal: true

# 依赖对账：blocked_by、Automation 块与正文依赖节必须三方一致。
# 引用说明（「另见 #35」）不算依赖，条件说明不算引用。
# 标题变体与代码围栏等 CommonMark 边界见 test_dependency_markdown.rb。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class DependencyReconciliationTest < Minitest::Test
  include SnapshotHelpers

  def test_blocked_by_conflicting_with_automation_is_invalid
    data = snapshot(issues: [
      issue(1, body: automation(depends_on: [], order: [4, 1]), blocked_by: [9]),
      issue(9, body: automation(order: [4, 2]))
    ])
    action = select(data)
    assert_equal "invalid_plan", action.action
    assert_includes action.reason, "blocked_by"
  end

  def test_completed_dependency_with_evidence_unlocks
    body = automation(depends_on: [9]) + evidence(subject: "issue:9")
    data = snapshot(issues: [
      issue(1, body: body, blocked_by: [9]),
      issue(9, body: evidence(subject: "issue:9"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 1, action.issue
  end

  def test_closed_not_planned_does_not_unlock
    data = snapshot(issues: [
      issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
      issue(9, body: evidence(subject: "issue:9"), state: "CLOSED", state_reason: "NOT_PLANNED")
    ])
    assert_equal "blocked", select(data).action
  end

  # #108 问题 2：前置已关闭时，正文依赖字段与 Automation 分叉仍要被检出。
  def test_prose_dependency_missing_from_automation_is_invalid
    body = automation(depends_on: [], prose: "WP1（#3）。")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: []),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "invalid_plan", action.action
    assert(action.reason.include?("正文依赖字段"), action.reason)
  end

  def test_automation_dependency_missing_from_prose_is_invalid
    body = automation(depends_on: [3], prose: "无。")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: [3]),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "invalid_plan", action.action
    assert(action.reason.include?("未出现在正文依赖字段"), action.reason)
  end

  def test_consistent_prose_and_automation_passes
    body = automation(depends_on: [3], prose: "WP1（#3）。")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: [3]),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "claim_issue", action.action
  end

  def test_prose_without_issue_numbers_is_not_checked
    body = automation(depends_on: [], prose: "M4.0-WP1 定稿。")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: [])
    ])
    action = select(data)
    assert_equal "claim_issue", action.action
  end

  # 卡面常写「另需外部依赖 E.5（见 #35 开工条件）」这类引用说明，
  # 其中的 #35 不是依赖，不能被当成 depends_on 缺失。
  def test_reference_only_issue_number_is_not_a_dependency
    body = automation(depends_on: [3], prose: "WP1（#3）完成；另需外部依赖 E.5（见 #35 开工条件）")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: [3]),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "claim_issue", action.action, action.reason
  end

  # CR：括号里带条件说明但仍是依赖，不能被整段剥掉。
  def test_dependency_paren_with_condition_note_is_kept
    body = automation(depends_on: [3], prose: "WP1（#3，开工条件已满足）")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: [3]),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "claim_issue", action.action, action.reason
  end

  # CR：同一行既有依赖又有引用说明时，只剥引用说明。
  def test_dependency_and_reference_on_same_line
    body = automation(depends_on: [3], prose: "WP1（#3）完成；另见 #35 开工条件")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: [3]),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "claim_issue", action.action, action.reason
  end

  def test_external_not_ready_blocks
    data = snapshot(
      issues: [issue(1, body: automation(depends_on: ["external:11"], external: ["11"]), blocked_by: [])],
      externals: {"external:11" => JSON.parse(evidence(subject: "external:11", status: "ready", ready: nil).scan(/\{.*\}/m).first)}
    )
    assert_equal "blocked", select(data).action
  end

end
