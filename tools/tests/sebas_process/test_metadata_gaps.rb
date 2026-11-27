# frozen_string_literal: true

# 元数据缺口：无 milestone / 无 Automation 的工作包信号识别，避免调度盲区。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class MetadataGapsTest < Minitest::Test
  include SnapshotHelpers

  # #114：无 milestone 的工作包卡此前完全隐形，只表现为笼统的「元数据未补齐」。
  def test_metadata_gaps_lists_work_package_without_milestone
    data = snapshot(issues: [
      # 有 plan 标签、有依赖声明，但没挂 milestone、没有 Automation
      issue(900, body: "## 前置依赖\n\nWP1（#3）。\n", labels: ["plan"], milestone: nil)
    ])
    action = select(data)
    assert_equal "blocked", action.action
    gap = action.metadata_gaps.find { |item| item["issue"] == 900 }
    refute_nil gap, "隐形卡必须出现在 metadata_gaps 中"
    assert_equal ["milestone", "automation"], gap["missing"]
  end

  def test_metadata_gaps_records_only_missing_milestone_when_automation_present
    data = snapshot(issues: [
      issue(901, body: automation(order: [4, 1]), milestone: nil)
    ])
    action = select(data)
    gap = action.metadata_gaps.find { |item| item["issue"] == 901 }
    refute_nil gap
    assert_equal ["milestone"], gap["missing"]
  end

  # 独立小修：Task + 无 milestone + work_package 块 = 正常形态，不是元数据缺口。
  def test_small_fix_without_milestone_is_not_a_metadata_gap
    data = snapshot(issues: [
      issue(903, body: automation(order: [4, 1]), milestone: nil, type: "Task")
    ])
    action = select(data)
    assert(action.metadata_gaps.none? { |item| item["issue"] == 903 })
  end

  def test_small_fix_with_dependencies_is_still_a_gap
    data = snapshot(issues: [
      issue(906, body: automation(order: [4, 1], depends_on: [7]), milestone: nil, type: "Task"),
      issue(2, body: automation(kind: "manual", order: [4, 2])),
      issue(7, body: automation(kind: "manual", order: [4, 3]))
    ])
    action = select(data)
    gap = action.metadata_gaps.find { |item| item["issue"] == 906 }
    refute_nil gap
    assert_equal ["milestone"], gap["missing"]
  end

  # 同样无 milestone，但 type 不是 Task 的就不算小修，仍要报缺口。
  def test_milestone_less_feature_is_still_a_gap
    data = snapshot(issues: [
      issue(904, body: automation(order: [4, 1]), milestone: nil, type: "Feature")
    ])
    action = select(data)
    gap = action.metadata_gaps.find { |item| item["issue"] == 904 }
    refute_nil gap
    assert_equal ["milestone"], gap["missing"]
  end

  # 小修不进自动选卡：主线 blocked 时不会拿它补位，只报主线 blocked。
  def test_small_fix_is_never_auto_selected
    data = snapshot(
      issues: [
        issue(1, body: automation(kind: "manual", order: [4, 1])),
        issue(905, body: automation(order: [4, 1]), milestone: nil, type: "Task")
      ],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 1),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 0)
      ]
    )
    action = select(data)
    assert_equal "blocked", action.action
    refute_equal 905, action.issue
  end

  def test_non_work_package_without_milestone_is_not_a_gap
    # 普通过 issue（无 plan、无依赖声明、无 Automation）不应污染清单。
    data = snapshot(issues: [
      issue(902, body: "只是一条建议\n", milestone: nil)
    ])
    action = select(data)
    assert_empty action.metadata_gaps
  end

  # CR：挂在 active milestone 内但缺 Automation 的卡，也要进 metadata_gaps——
  # 它的 excluded 条目会淹没在「前置阻塞」里，单靠 reason 难以定位。
  def test_metadata_gaps_lists_milestoned_card_without_automation
    data = snapshot(issues: [
      issue(903, body: "## 前置依赖\n\nWP1（#3）。\n", blocked_by: [3])
    ])
    action = select(data)
    assert_equal "blocked", action.action
    assert(action.excluded.any? { |e| e["issue"] == 903 }, "仍应出现在 excluded")
    gap = action.metadata_gaps.find { |item| item["issue"] == 903 }
    refute_nil gap, "缺 Automation 的 milestone 卡必须进 gaps"
    assert_equal ["automation"], gap["missing"]
  end

  def test_milestoned_tracking_card_is_not_a_gap
    # tracking 卡（有 Automation、kind=tracking）不缺任何元数据，只是不参与调度。
    data = snapshot(issues: [
      issue(904, body: automation(kind: "tracking", order: [4, 0]), blocked_by: [])
    ])
    action = select(data)
    assert_empty action.metadata_gaps.select { |g| g["issue"] == 904 }
  end

  def test_design_card_is_not_a_gap_even_without_milestone
    # design 卡归 Scribe，不进 Implementer 的缺口提示。
    data = snapshot(issues: [
      issue(905, body: automation(kind: "design", order: [4, 0]), milestone: nil)
    ])
    action = select(data)
    assert_empty action.metadata_gaps.select { |g| g["issue"] == 905 }
  end

  # CR：依赖节里只有引用说明（「另见 #35」）也算工作包信号。
  def test_reference_only_dependency_section_counts_as_work_package
    body = "## 前置依赖\n\n另见 #35 开工条件。\n"
    data = snapshot(issues: [
      issue(905, body: body, milestone: nil)
    ])
    action = select(data)
    gap = action.metadata_gaps.find { |item| item["issue"] == 905 }
    refute_nil gap, "引用说明也应视为依赖节信号"
    assert_equal ["milestone", "automation"], gap["missing"]
  end

  def test_card_in_other_milestone_is_not_a_gap
    # 挂到别的 milestone 的卡不归本 active 主线调度，不能算缺口。
    data = snapshot(
      issues: [issue(906, body: "## 前置依赖\n\nWP1（#3）。\n", milestone: 1)],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 1),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
      ]
    )
    action = select(data)
    assert_empty action.metadata_gaps.select { |g| g["issue"] == 906 }
  end

  # CR：依赖节下的子标题不能提前截断节内容。
  def test_nested_heading_inside_dependency_section
    body = "## 前置依赖\n### 内部依赖\n依赖 #3\n"
    data = snapshot(issues: [issue(907, body: body, milestone: nil)])
    action = select(data)
    gap = action.metadata_gaps.find { |item| item["issue"] == 907 }
    refute_nil gap, "子标题之后的内容仍属依赖节"
    assert_equal ["milestone", "automation"], gap["missing"]
  end

  def test_sibling_heading_ends_dependency_section
    # 同级标题（## 验收）应结束依赖节；其后的 #3 不算依赖信号。
    body = "## 前置依赖\n\n无\n\n## 验收\n\n参见 #3 的说明\n"
    data = snapshot(issues: [issue(908, body: body, milestone: nil)])
    action = select(data)
    assert_empty action.metadata_gaps.select { |g| g["issue"] == 908 }
  end

  # CR：`#3` 是 issue 引用，不是一级标题；不能被当成节结束。
  def test_issue_reference_at_line_start_is_not_a_heading
    body = "## 前置依赖\n#3\n"
    data = snapshot(issues: [issue(909, body: body, milestone: nil)])
    action = select(data)
    gap = action.metadata_gaps.find { |item| item["issue"] == 909 }
    refute_nil gap, "行首 #3 是引用而非标题，依赖节不应在此结束"
  end

  def test_metadata_gaps_absent_when_claimable_card_exists
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1]), blocked_by: []),
      issue(900, body: "## 前置依赖\n\nWP1（#3）。\n", labels: ["plan"], milestone: nil)
    ])
    action = select(data)
    assert_equal "claim_issue", action.action
    # 有可认领卡时不返回 blocked，因此不产出 gaps（保持输出精简）。
    assert_empty action.metadata_gaps
  end
end
