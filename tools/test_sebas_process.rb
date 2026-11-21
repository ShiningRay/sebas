# frozen_string_literal: true

# sebas-process 回归测试。全部基于固定 JSON 快照，不访问网络。
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "agents/lib/sebas_agents"

module SnapshotHelpers
  def automation(kind: "work_package", order: [1], depends_on: [], external: [], prose: nil)
    prose_section = prose ? "\n## 前置依赖\n\n#{prose}\n" : ""
    body = <<~MD
      ## 目标
      测试
      #{prose_section}
      ```json automation
      #{" "}
      MD
    body.sub("#{" "}\n", "") + JSON.pretty_generate(
      {
        "schema" => 1,
        "kind" => kind,
        "order" => order,
        "depends_on" => depends_on,
        "external" => external
      }
    ) + "\n```\n"
  end

  def evidence(subject:, status: "accepted", ready: nil, merged: true, untested: [],
    gate_status: nil, evidence_path: nil, source: "maintainer")
    block = {
      "schema" => 1,
      "subject" => subject,
      "status" => status,
      "source" => source,
      "source_ref" => "https://github.com/o/r/issues/1#issuecomment-1",
      "pr" => 10,
      "merge_commit" => "abc123",
      "merged_into_main" => merged,
      "checks" => "https://ci/1",
      "gate_status" => gate_status,
      "evidence_path" => evidence_path,
      "untested" => untested,
      "ready" => ready
    }
    "```json evidence\n#{JSON.pretty_generate(block)}\n```\n"
  end

  def issue(number, body: "", labels: [], milestone: 2, state: "OPEN", state_reason: nil, blocked_by: [])
    {
      "number" => number,
      "title" => "issue #{number}",
      "state" => state,
      "state_reason" => state_reason,
      "body" => body,
      "labels" => labels,
      "milestone" => milestone,
      "assignees" => [],
      "blocked_by" => blocked_by
    }
  end

  def milestone(number:, order:, track:, open_issues: 0, state: "open")
    {
      "number" => number,
      "title" => "M#{order}",
      "state" => state,
      "order" => order,
      "track" => track,
      "open_issues" => open_issues,
      "description" => "order: #{order}\ntrack: #{track}\n"
    }
  end

  def snapshot(issues:, milestones: nil, pull_requests: [], maintainers: ["ShiningRay"],
    source_authors: nil, gates: {}, externals: {}, trusted_bots: [], source_bodies: {})
    {
      "repo" => "o/r",
      "main_sha" => "deadbeef",
      "milestones" => milestones || [
        milestone(number: 2, order: "4", track: "main", open_issues: issues.length),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 5)
      ],
      "issues" => issues,
      "pull_requests" => pull_requests,
      "maintainers" => maintainers,
      "source_authors" => source_authors || {
        "https://github.com/o/r/issues/1#issuecomment-1" => "ShiningRay"
      },
      "gates" => gates,
      "externals" => externals,
      "trusted_bots" => trusted_bots,
      "source_bodies" => source_bodies
    }
  end

  def select(data, record: nil)
    SebasAgents::Policy::Selection.select_action(SebasAgents::Model::Snapshot.from_hash(data), record: record)
  end
end

class MilestonePolicyTest < Minitest::Test
  include SnapshotHelpers

  def normalize(milestones)
    SebasAgents::Policy::Milestones.normalize(milestones.map { |item| SebasAgents::Model::Milestone.from_hash(item) })
  end

  def test_main_and_parallel_same_number_coexist
    items = normalize([
      {"number" => 2, "title" => "M4", "state" => "open", "order" => "4", "track" => "main", "open_issues" => 3, "description" => "order: 4
track: main
"},
      {"number" => 1, "title" => "M4x", "state" => "open", "order" => "4x", "track" => "parallel", "open_issues" => 9, "description" => "order: 4x
track: parallel
"}
    ])
    assert_equal 2, items.length
    assert_equal [:select, 2], SebasAgents::Policy::Milestones.active(items).then { |(state, item)| [state, item.number] }
  end

  def test_duplicate_main_order_is_invalid
    error = assert_raises(SebasAgents::InvalidPlan) do
      normalize([
        {"number" => 2, "title" => "a", "state" => "open", "order" => "4", "track" => "main", "open_issues" => 1, "description" => "order: 4
track: main
"},
        {"number" => 3, "title" => "b", "state" => "open", "order" => "4", "track" => "main", "open_issues" => 1, "description" => "order: 4
track: main
"}
      ])
    end
    assert_includes error.message, "重复"
  end

  def test_missing_metadata_is_invalid
    assert_raises(SebasAgents::InvalidPlan) do
      normalize([{"number" => 2, "title" => "a", "state" => "open", "description" => ""}])
    end
  end

  def test_parallel_track_does_not_participate
    items = normalize([
      {"number" => 1, "title" => "M4x", "state" => "open", "order" => "1x", "track" => "parallel", "open_issues" => 9, "description" => "order: 1x
track: parallel
"},
      {"number" => 2, "title" => "M5", "state" => "open", "order" => "5", "track" => "main", "open_issues" => 1, "description" => "order: 5
track: main
"}
    ])
    state, active = SebasAgents::Policy::Milestones.active(items)
    assert_equal :select, state
    assert_equal 2, active.number
  end

  def test_open_without_work_hands_off_release
    items = normalize([
      {"number" => 2, "title" => "M4", "state" => "open", "order" => "4", "track" => "main", "open_issues" => 0, "description" => "order: 4
track: main
"}
    ])
    assert_equal :handoff_release, SebasAgents::Policy::Milestones.active(items).first
  end

  def test_all_closed_is_idle
    items = normalize([
      {"number" => 2, "title" => "M4", "state" => "closed", "order" => "4", "track" => "main", "open_issues" => 0, "description" => "order: 4
track: main
"}
    ])
    assert_equal :idle, SebasAgents::Policy::Milestones.active(items).first
  end

  def test_non_numeric_main_order_is_invalid
    assert_raises(SebasAgents::InvalidPlan) do
      normalize([{"number" => 2, "title" => "a", "state" => "open", "order" => "4x", "track" => "main", "open_issues" => 1, "description" => "order: 4x
track: main
"}])
    end
  end
end

class SelectionTest < Minitest::Test
  include SnapshotHelpers

  def test_picks_lowest_order_ready_card
    data = snapshot(issues: [
      issue(39, body: automation(order: [4, 0, 2])),
      issue(40, body: automation(order: [4, 0, 1]))
    ])
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 40, action.issue
  end

  def test_missing_automation_blocks_with_reason
    data = snapshot(issues: [issue(39, body: "无元数据")])
    action = select(data)
    assert_equal "blocked", action.action
    assert_equal 39, action.excluded.first["issue"]
    assert_includes action.excluded.first["reason"], "Automation"
  end

  def test_plan_label_without_automation_is_excluded
    data = snapshot(issues: [issue(39, labels: ["plan"], body: "计划卡")])
    action = select(data)
    assert_equal "blocked", action.action
    assert_equal 1, action.excluded.length
  end

  def test_tracking_and_manual_excluded
    data = snapshot(issues: [
      issue(1, body: automation(kind: "tracking")),
      issue(2, body: automation(kind: "manual")),
      issue(3, body: automation(order: [4]))
    ])
    action = select(data)
    assert_equal 3, action.issue
  end

  # §3.2：暂停卡未放行时整轮停手，不得换卡并发
  def test_needs_human_blocks_new_work
    data = snapshot(issues: [
      issue(1, body: automation, labels: ["needs:human"]),
      issue(2, body: automation(order: [4]))
    ])
    action = select(data)
    assert_equal "needs_human", action.action
    assert_equal 1, action.issue
  end

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

  def test_completed_dependency_without_evidence_blocks
    data = snapshot(issues: [
      issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
      issue(9, body: "", state: "CLOSED", state_reason: "COMPLETED")
    ])
    assert_equal "blocked", select(data).action
  end

  def test_evidence_from_non_maintainer_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9"), state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "random-user"}
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_evidence_from_trusted_bot_unlocks
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      trusted_bots: ["github-actions[bot]"]
    )
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 1, action.issue
  end

  def test_evidence_from_bot_not_in_trusted_list_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "evil-bot[bot]"},
      trusted_bots: ["github-actions[bot]"]
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_bot_cannot_forge_maintainer_source
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "maintainer"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      trusted_bots: ["github-actions[bot]"]
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_workflow_source_without_trusted_bots_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      trusted_bots: []
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_unknown_source_value_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "root"),
          state: "CLOSED", state_reason: "COMPLETED")
      ]
    )
    assert_equal "invalid_plan", select(data).action
  end

  # CR 安全项：作者合法但评论正文没有登记本结论时，不能放行。
  def test_trusted_bot_with_unrelated_comment_body_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => "LGTM, merging soon."},
      trusted_bots: ["github-actions[bot]"]
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_trusted_bot_with_matching_evidence_body_unlocks
    registered = evidence(subject: "issue:9", source: "workflow")
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => registered},
      trusted_bots: ["github-actions[bot]"]
    )
    assert_equal "claim_issue", select(data).action
  end

  def test_evidence_body_with_different_subject_is_invalid
    registered = evidence(subject: "issue:99")
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => registered}
    )
    assert_equal "invalid_plan", select(data).action
  end

  # CR：issue 正文把 untested 改成 [] 不能绕过门禁——必须与登记评论一致。
  def test_evidence_untested_mismatch_is_invalid
    registered = evidence(subject: "issue:9", untested: ["真机 round-trip"])
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        # issue 正文宣称无未实测项
        issue(9, body: evidence(subject: "issue:9", untested: []),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => registered}
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_evidence_untested_match_passes
    registered = evidence(subject: "issue:9", untested: ["真机 round-trip"])
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", untested: ["真机 round-trip"]),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => registered}
    )
    # 登记与正文一致，但仍有未实测项 → 依赖不满足（blocked，而非 invalid）。
    assert_equal "blocked", select(data).action
  end

  def test_external_not_ready_blocks
    data = snapshot(
      issues: [issue(1, body: automation(depends_on: ["external:11"], external: ["11"]), blocked_by: [])],
      externals: {"external:11" => JSON.parse(evidence(subject: "external:11", status: "ready", ready: nil).scan(/\{.*\}/m).first)}
    )
    assert_equal "blocked", select(data).action
  end

  def test_duplicate_order_is_invalid
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1])),
      issue(2, body: automation(order: [4, 1]))
    ])
    action = select(data)
    assert_equal "invalid_plan", action.action
    assert_includes action.reason, "重复"
  end

  def test_dependency_cycle_is_invalid
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1], depends_on: [2]), blocked_by: [2]),
      issue(2, body: automation(order: [4, 2], depends_on: [1]), blocked_by: [1])
    ])
    assert_equal "invalid_plan", select(data).action
  end

  def test_multiple_in_progress_is_invalid
    data = snapshot(issues: [
      issue(1, body: automation, labels: ["agent:in-progress"]),
      issue(2, body: automation, labels: ["agent:in-progress"])
    ])
    assert_equal "invalid_plan", select(data).action
  end

  def test_own_pull_request_resumes_before_new_card
    pr = {
      "number" => 50, "head_ref_name" => "feat/1", "state" => "OPEN",
      "merge_state_status" => "BEHIND", "checks" => [],
      "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(
      issues: [issue(1, body: automation, labels: ["agent:in-progress"]), issue(2, body: automation(order: [4, 2]))],
      pull_requests: [pr]
    )
    action = select(data, record: {"issue" => 1, "pr" => 50, "phase" => "claimed"})
    assert_equal "resume_pr", action.action
    assert_includes action.reason, "BEHIND"
  end

  def test_pending_ci_waits
    pr = {
      "number" => 50, "state" => "OPEN", "merge_state_status" => "UNKNOWN",
      "checks" => [{"name" => "spec", "status" => "IN_PROGRESS", "conclusion" => nil}],
      "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(
      issues: [issue(1, body: automation, labels: ["agent:in-progress"])],
      pull_requests: [pr]
    )
    assert_equal "wait", select(data, record: {"issue" => 1, "pr" => 50}).action
  end

  def test_claiming_interruption_resumes
    data = snapshot(issues: [issue(1, body: automation, labels: ["agent:in-progress"])])
    action = select(data, record: {"issue" => 1, "phase" => "claiming"})
    assert_equal "resume_issue", action.action
    assert_includes action.reason, "claiming"
  end

  def test_paused_with_resume_returns_resume
    data = snapshot(issues: [issue(1, body: automation, labels: %w[needs:human agent:resume agent:in-progress])])
    action = select(data, record: {"issue" => 1, "phase" => "paused"})
    assert_equal "resume_issue", action.action
    assert_includes action.reason, "agent:resume"
  end

  def test_local_remote_conflict_is_invalid
    data = snapshot(issues: [issue(1, body: automation, labels: ["agent:in-progress"])])
    assert_equal "invalid_plan", select(data, record: {"issue" => 99}).action
  end

  def test_handoff_release_when_no_open_issues
    data = snapshot(issues: [], milestones: [
      {"number" => 2, "title" => "M4", "state" => "open", "order" => "4", "track" => "main", "open_issues" => 0, "description" => "order: 4
track: main
"}
    ])
    assert_equal "handoff_release", select(data).action
  end

  def test_excluded_lists_every_blocked_candidate
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1], depends_on: [9]), blocked_by: [9]),
      issue(9, body: automation(order: [4, 9]), blocked_by: [])
    ])
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 9, action.issue
    assert(action.excluded.any? { |item| item["issue"] == 1 })
  end

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

class VerifierTest < Minitest::Test
  include SnapshotHelpers

  def test_docs_reports_line_anchors_and_size
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "见 design.md:L12\n" + ("填充\n" * 410), encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_docs(["doc.md"], root: dir, max_lines: 400)
      refute report.pass?
      assert report.must_fix_items.any? { |item| item.message.include?("行号锚") }
      assert report.must_fix_items.any? { |item| item.message.include?("超过") }
    end
  end

  def test_archive_line_anchor_is_acceptable
    Dir.mktmpdir do |dir|
      path = File.join(dir, "docs/design/review/x.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "见 design.md:L12\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_docs(["docs/design/review/x.md"], root: dir)
      assert report.pass?
      assert_equal 1, report.acceptable_items.length
    end
  end

  def test_missing_file_blocks
    Dir.mktmpdir do |dir|
      report = SebasAgents::Verifier.verify_docs(["missing.md"], root: dir)
      assert_equal 1, report.blockers.length
    end
  end

  def test_code_anchor_mismatch
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "x.cr"), "真实内容\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_code_anchors(
        [{"file" => "src/x.cr", "line" => 1, "content" => "文档声称"}], root: dir
      )
      assert_equal 1, report.must_fix_items.length
    end
  end

  def test_verify_merge_requires_completed_issue
    data = snapshot(
      issues: [issue(39, body: automation, state: "CLOSED", state_reason: "NOT_PLANNED")],
      pull_requests: [{"number" => 10, "state" => "MERGED", "closing_issues" => [39]}]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data))
    refute report.pass?
  end
end

class ReviewerTest < Minitest::Test
  def verification_with(items)
    report = SebasAgents::VerificationReport.new
    items.each do |level, message|
      report.public_send(level, message)
    end
    report
  end

  def test_unresolved_must_fix_blocks
    report = verification_with([["must_fix", "锚点不符"]])
    final = SebasAgents::Reviewer.final_verification(report, {})
    refute final.pass?
    assert_equal "打回", final.conclusion
  end

  def test_self_reported_fix_is_conditional
    report = verification_with([["must_fix", "锚点不符"]])
    fixes = {"must_fix-1" => {"passed" => true, "commit" => "abc"}}
    final = SebasAgents::Reviewer.final_verification(report, fixes)
    assert final.pass?
    assert_equal "有条件通过", final.conclusion
  end

  def test_independent_checker_required
    report = verification_with([["must_fix", "锚点不符"]])
    checker = ->(_item, _fix) { {passed: true} }
    final = SebasAgents::Reviewer.final_verification(report, {"must_fix-1" => {}}, checker: checker)
    assert final.pass?
    assert_equal "通过", final.conclusion
  end

  def test_verifier_blocker_propagates
    report = verification_with([["blocker", "缺文件"]])
    assert_equal "打回", SebasAgents::Reviewer.final_verification(report, {}).conclusion
  end

  # #109：fixes 用条目自身 id 也要能匹配，不能只认 level 自编号。
  def test_fixes_keyed_by_item_id_matches
    report = verification_with([["must_fix", "锚点不符"]])
    report = SebasAgents::VerificationReport.new
    report.must_fix("锚点不符", id: "g")
    fixes = {"g" => {"passed" => true, "commit" => "abc"}}
    final = SebasAgents::Reviewer.final_verification(report, fixes)
    assert final.pass?
    assert_equal "有条件通过", final.conclusion
  end

  def test_item_id_kept_in_report
    report = SebasAgents::VerificationReport.new
    report.must_fix("锚点不符", id: "r2-1")
    assert_equal "r2-1", report.items.first.id
  end

  def test_auto_id_is_per_level
    report = SebasAgents::VerificationReport.new
    report.must_fix("a")
    report.acceptable("b")
    report.must_fix("c")
    assert_equal %w[must_fix-1 acceptable-1 must_fix-2], report.items.map(&:id)
  end

  # CR：显式 id 与生成的 fallback id 不得碰撞。
  def test_explicit_id_does_not_collide_with_generated
    report = SebasAgents::VerificationReport.new
    report.must_fix("a")
    report.must_fix("b", id: "must_fix-2")
    report.must_fix("c")
    assert_equal %w[must_fix-1 must_fix-2 must_fix-3], report.items.map(&:id)
    assert_equal 3, report.items.map(&:id).uniq.length
  end

  def test_duplicate_explicit_id_is_rejected
    report = SebasAgents::VerificationReport.new
    report.must_fix("a", id: "g")
    assert_raises(ArgumentError) { report.must_fix("b", id: "g") }
  end

  # CR：positional fallback 按 level 内序号，不由 id 后缀推断。
  def test_positional_fallback_is_not_derived_from_id_suffix
    report = SebasAgents::VerificationReport.new
    report.must_fix("a", id: "r2-1")
    report.must_fix("b", id: "r3-1")
    fixes = {"must_fix-1" => {"passed" => true, "commit" => "aaa"}}
    final = SebasAgents::Reviewer.final_verification(report, fixes)
    # 只有第 1 项被覆盖，第 2 项必须仍算未修复。
    assert_equal "打回", final.conclusion
  end

  # CR：level-only 简写只在同 level 唯一时生效。
  def test_level_only_fix_requires_unique_item
    two = SebasAgents::VerificationReport.new
    two.must_fix("a")
    two.must_fix("b")
    fixes = {"must_fix" => {"passed" => true, "commit" => "aaa"}}
    assert_equal "打回", SebasAgents::Reviewer.final_verification(two, fixes).conclusion

    one = SebasAgents::VerificationReport.new
    one.must_fix("a")
    assert_equal "有条件通过", SebasAgents::Reviewer.final_verification(one, fixes).conclusion
  end

  # CR：位置键不能命中另一条目的显式 id，否则一条 fix 满足两项。
  def test_positional_key_does_not_shadow_other_item_explicit_id
    report = SebasAgents::VerificationReport.new
    report.must_fix("a", id: "must_fix-2")   # 显式 id 恰好等于第二项的位置键
    report.must_fix("b", id: "g")
    fixes = {"must_fix-2" => {"passed" => true, "commit" => "aaa"}}
    final = SebasAgents::Reviewer.final_verification(report, fixes)
    # 第 1 项按显式 id 命中；第 2 项的位置键 must_fix-2 被占用，不得复用 → 仍算未修复。
    assert_equal "打回", final.conclusion
  end

  # CR：level-only 简写同样不能命中另一条目的显式 id。
  def test_level_only_key_does_not_shadow_other_item_explicit_id
    report = SebasAgents::VerificationReport.new
    report.must_fix("a", id: "acceptable")
    report.acceptable("b", id: "g")
    fixes = {"acceptable" => {"passed" => true, "commit" => "abc", "reason_still_valid" => true}}
    final = SebasAgents::Reviewer.final_verification(report, fixes)
    # "acceptable" 是第 1 项的显式 id，第 2 项不得再借它过关。
    assert_equal "打回", final.conclusion
  end
end

# #109：叙述式 verdict 与 level 词汇统一由 VERDICTS 收口。
class VerdictMappingTest < Minitest::Test
  def test_chinese_verdicts_map_to_levels
    expected = {
      "阻断" => "blocker",
      "应修" => "must_fix",
      "可留" => "acceptable",
      "未实测" => "unverified",
      "通过" => "ok"
    }
    expected.each do |verdict, level|
      assert_equal level, SebasAgents::VerificationReport::VERDICTS.fetch(verdict), "映射 #{verdict}"
    end
  end

  def test_english_levels_pass_through
    %w[blocker must_fix acceptable unverified ok pass].each do |level|
      refute_nil SebasAgents::VerificationReport::VERDICTS[level], "缺少 #{level}"
    end
  end
end

class ReleaseTest < Minitest::Test
  def test_fix_only_bumps_patch
    plan = SebasAgents::Release.plan(latest_tag: "v0.1.0", subjects: ["fix(a): b", "docs: c"])
    assert_equal "patch", plan["action"]
    assert_equal "0.1.1", plan["next_version"]
  end

  def test_feat_blocks_patch
    plan = SebasAgents::Release.plan(latest_tag: "v0.1.0", subjects: ["fix(a): b", "feat: d"])
    assert_equal "skip", plan["action"]
  end

  def test_no_fix_is_noop
    plan = SebasAgents::Release.plan(latest_tag: "v0.1.0", subjects: ["docs: c"])
    assert_equal "noop", plan["action"]
  end

  def test_scoped_fix_matches
    plan = SebasAgents::Release.plan(latest_tag: "v1.2.9", subjects: ["fix(orchestration): x"])
    assert_equal "1.2.10", plan["next_version"]
  end
end

class CliTest < Minitest::Test
  include SnapshotHelpers

  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = SebasAgents::CLI.new(out: out, err: err).run(argv)
    [status, out.string, err.string]
  end

  def test_unknown_command_returns_usage
    status, out, = run_cli(["nope"])
    assert_equal 2, status
    assert_includes out, "usage_error"
  end

  def test_roles_lists_all
    status, out, = run_cli(["roles"])
    assert_equal 0, status
    assert_includes out, "release-manager"
  end

  def test_role_prompt_uses_real_commands
    status, out, = run_cli(%w[roles implementer --json])
    assert_equal 0, status
    documented = JSON.parse(out)["commands"]
    help_out = StringIO.new
    SebasAgents::CLI.new(out: help_out, err: StringIO.new).run(["help"])
    documented.each do |command|
      subcommand = command.split[2]
      assert_includes help_out.string, subcommand
    end
  end

    def test_oneline_is_single_line_for_every_role
    %w[implementer verifier reviewer triager scribe release-manager maintainer].each do |role|
      status, out, = run_cli(["roles", role, "--one-line"])
      assert_equal 0, status, role
      assert_equal 1, out.lines.length, "#{role} 的一句话必须是一行"
      assert_includes out, "sebas"
    end
  end

  def test_oneline_all_roles
    status, out, = run_cli(%w[roles --one-line])
    assert_equal 0, status
    assert_equal SebasAgents::RolePrompts::ROLES.length, out.lines.length
    assert_includes out, "Implementer"
    assert_includes out, "Release Manager"
  end

  def test_oneline_names_the_first_command
    status, out, = run_cli(%w[roles implementer --one-line])
    assert_equal 0, status
    assert_includes out, "ruby tools/sebas-process next"
    assert_includes out, "verify merge"
    assert_includes out, "禁 force-push"
  end

  def test_role_prompt_is_plain_text_ready_to_paste
    %w[implementer verifier reviewer triager scribe release-manager maintainer].each do |role|
      status, out, = run_cli(["roles", role, "--prompt-only"])
      assert_equal 0, status, role
      assert_includes out, "角色：sebas #{role}"
      assert_includes out, "权限边界"
      assert_includes out, "第一步"
      assert_includes out, "停止条件"
      assert_includes out, "退出码"
      refute out.start_with?("{"), "prompt-only 不应输出 JSON"
    end
  end

  def role_display(role)
    role.split("-").map(&:capitalize).join(" ")
  end

  def test_role_prompt_forbids_writes_for_read_only_roles
    %w[verifier reviewer].each do |role|
      _status, out, = run_cli(["roles", role, "--prompt-only"])
      assert_includes out, "只读"
      assert_includes out, "禁止："
    end
  end

  def test_prompt_only_requires_role
    status, out, = run_cli(%w[roles --prompt-only])
    assert_equal 2, status
    assert_includes out, "usage_error"
  end

  def test_roles_without_role_lists_all
    status, out, = run_cli(["roles"])
    assert_equal 0, status
    payload = JSON.parse(out)["roles"]
    assert_equal SebasAgents::RolePrompts::ROLES.sort, payload.keys.sort
  end

  def test_triage_with_verdict_produces_actions
    data = snapshot(issues: [issue(7, body: "bug 描述", labels: [])])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      verdict = File.join(dir, "v.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      File.write(verdict, JSON.generate({"decision" => "bug-confirmed", "body" => "复现步骤"}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "7", "--snapshot", snap, "--verdict", verdict])
      assert_equal 0, status
      payload = JSON.parse(out)
      assert_equal "bug-confirmed", payload["decision"]
      assert(payload["actions"].any? { |action| action["name"] == "bug" })
    end
  end

  def test_triage_without_verdict_asks_model
    data = snapshot(issues: [issue(7, body: "bug 描述")])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "7", "--snapshot", snap])
      assert_equal 1, status
      assert_equal "needs-model-verdict", JSON.parse(out)["decision"]
    end
  end

  def test_next_with_snapshot
    data = snapshot(issues: [issue(1, body: automation(order: [4]))])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["next", "--snapshot", path, "--record", File.join(dir, "run.json")])
      assert_equal 0, status
      assert_equal "claim_issue", JSON.parse(out)["action"]
    end
  end

  def test_invalid_plan_exits_refused
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1])),
      issue(2, body: automation(order: [4, 1]))
    ])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["next", "--snapshot", path, "--record", File.join(dir, "run.json")])
      assert_equal 1, status
      payload = JSON.parse(out)
      assert_equal "invalid_plan", payload["action"]
      refute payload["ok"]
    end
  end

  def test_claim_dry_run_does_not_write_record
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["claim", "1", "--snapshot", path, "--record", record])
      assert_equal 0, status
      assert JSON.parse(out)["dry_run"]
      refute File.exist?(record)
    end
  end

  # --apply 需要真实标签写入与回读；此处只验证 dry-run 不落盘，
  # 以及写授权机制本身（见 DryRunGuardTest）。
  def test_claim_apply_claims_only_with_verified_label
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["claim", "1", "--snapshot", path, "--record", record, "--apply",
        "--repo", "invalid/does-not-exist-zzz"])
      # 仓库不可达时不得声称 claimed
      assert_includes [1, 2], status
      payload = JSON.parse(out)
      refute_equal "claimed", payload["claim"]
    end
  end

  # 快照仓库与 --repo 不一致时必须拒绝写入，否则会认领到没校验过的仓库。
  def test_claim_rejects_repo_mismatch
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["claim", "1", "--snapshot", path, "--record", record, "--apply",
        "--repo", "other/repo"])
      assert_equal 2, status
      assert_equal "usage_error", JSON.parse(out)["error"]["code"]
      refute File.exist?(record), "拒绝时不得留下运行记录"
    end
  end

  # 写入失败也要落 aborted，不能让记录停在 claiming。
  def test_claim_write_failure_records_aborted
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")

      # 用假 runner：写标签抛错，其余按成功返回。
      fake = Class.new(SebasAgents::CommandRunner) do
        def run!(*argv, chdir: Dir.pwd)
          raise SebasAgents::CommandError.new("boom", command: argv) if argv.include?("--add-label")

          ""
        end
      end

      cli = SebasAgents::CLI.new(out: StringIO.new, err: StringIO.new)
      cli.define_singleton_method(:runner) { |_options| fake.new(dry_run: false) }
      out = StringIO.new
      cli.instance_variable_set(:@out, out)
      status = cli.run(["claim", "1", "--snapshot", path, "--record", record, "--apply"])
      assert_equal 1, status
      saved = JSON.parse(File.read(record, encoding: "UTF-8"))
      assert_equal "aborted", saved["phase"], "写入失败必须落 aborted"
      assert_equal false, saved["label_written"]
      refute JSON.parse(out.string)["ok"]
    end
  end

  def test_dry_run_blocks_git_writes
    runner = SebasAgents::CommandRunner.new(dry_run: true)
    result = runner.capture("git", "push", "origin", "main")
    assert result.success?
    assert_equal [%w[git push origin main]], runner.calls
  end
end

class JsonBlockTest < Minitest::Test
  def test_rejects_duplicate_blocks
    body = "```json automation\n{\"kind\":\"work_package\"}\n```\n```json automation\n{\"kind\":\"tracking\"}\n```\n"
    assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::JsonBlock.one(body, "automation", subject: "issue #1")
    end
  end

  def test_rejects_invalid_json
    assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::JsonBlock.one("```json automation\n{nope}\n```\n", "automation", subject: "issue #1")
    end
  end

  def test_ignores_unlabelled_json_fence
    body = "```json\n{\"kind\":\"tracking\"}\n```\n"
    assert_nil SebasAgents::JsonBlock.one(body, "automation", subject: "issue #1")
  end

  # Windows 客户端写的 issue body 是 CRLF；曾导致所有元数据"看起来不存在"。
  def test_parses_crlf_body
    body = "## Automation\r\n\r\n```json automation\r\n{\"schema\":1,\"kind\":\"work_package\"}\r\n```\r\n"
    parsed = SebasAgents::JsonBlock.one(body, "automation", subject: "issue #1")
    assert_equal "work_package", parsed["kind"]
    assert SebasAgents::JsonBlock.present?(body, "automation")
  end

  def test_parses_mixed_line_endings
    body = "text\r\n```json automation\n{\"kind\":\"tracking\"}\r\n```\n"
    assert_equal "tracking", SebasAgents::JsonBlock.one(body, "automation", subject: "issue #1")["kind"]
  end
end

class DryRunGuardTest < Minitest::Test
  # 复核列出的真实写命令形态，全部必须被拦。
  WRITE_COMMANDS = [
    %w[git push origin main],
    %w[git commit -m x],
    %w[git tag v1.0.0],
    %w[git checkout -b feat/x],
    %w[git switch main],
    %w[git reset --hard],
    %w[git add -A],
    %w[git stash],
    ["git", "-C", "/repo", "commit", "-m", "x"],
    ["git", "--git-dir", "/repo/.git", "commit", "-m", "x"],
    ["gh", "issue", "edit", "1", "--add-label", "bug"],
    ["gh", "issue", "close", "1"],
    ["gh", "issue", "comment", "1", "--body", "x"],
    ["gh", "issue", "develop", "1"],
    ["gh", "pr", "merge", "5", "--squash"],
    ["gh", "pr", "create", "--title", "t"],
    ["gh", "pr", "update-branch", "5"],
    ["gh", "-R", "o/r", "pr", "merge", "5"],
    ["gh", "--repo", "o/r", "issue", "comment", "1", "--body", "x"],
    ["gh", "label", "create", "bug"],
    ["gh", "api", "repos/o/r/issues/1", "-X", "POST", "-f", "body=x"],
    ["gh", "api", "repos/o/r/issues/1/comments", "-f", "body=x"],
    ["gh", "api", "repos/o/r/issues/1/comments", "-fbody=x"],
    ["gh", "api", "repos/o/r/issues", "--input", "payload.json"],
    ["gh", "api", "--method=POST", "repos/o/r/issues"],
    ["gh", "api", "-X", "DELETE", "repos/o/r/issues/1"],
    ["gh", "release", "create", "v1.0.0"],
    ["gh", "release", "upload", "v1", "f.zip"]
  ].freeze

  READ_COMMANDS = [
    %w[git log --oneline],
    %w[git describe --tags --abbrev=0],
    %w[git rev-parse HEAD],
    %w[git status --short],
    ["git", "-C", "/repo", "log", "--oneline"],
    ["gh", "api", "repos/o/r/issues"],
    ["gh", "api", "-X", "GET", "repos/o/r/issues", "-f", "state=open"],
    # graphql 的 -f 只是查询变量，必须放行，否则默认 next 在有 open PR 时必失败
    ["gh", "api", "graphql", "-f", "query=query{viewer{login}}"],
    ["gh", "pr", "list", "--json", "number"],
    ["gh", "pr", "view", "5", "--json", "state"],
    ["gh", "issue", "view", "1", "--json", "body"],
    ["gh", "issue", "list", "--json", "number"],
    ["gh", "-R", "o/r", "issue", "view", "1"],
    ["gh", "status"]
  ].freeze

  def test_write_commands_are_never_executed
    WRITE_COMMANDS.each do |argv|
      runner = SebasAgents::CommandRunner.new(dry_run: true)
      refute runner.send(:read_only?, argv), "未拦截写命令：#{argv.join(" ")}"
      result = runner.capture(*argv)
      assert result.success?, "dry-run 应返回假成功：#{argv.join(" ")}"
      assert_equal "", result.stdout, "dry-run 不得返回伪数据：#{argv.join(" ")}"
    end
  end

  def test_read_commands_are_executed
    READ_COMMANDS.each do |argv|
      runner = SebasAgents::CommandRunner.new(dry_run: true)
      assert runner.send(:read_only?, argv), "误把只读命令当写：#{argv.join(" ")}"
    end
  end

  def test_unknown_command_is_blocked_by_default
    # 白名单语义：无法确认只读的命令默认不执行。
    runner = SebasAgents::CommandRunner.new(dry_run: true)
    refute runner.send(:read_only?, ["curl", "https://example.com"]), "未知命令应默认拦截"
    refute runner.send(:read_only?, ["gh", "extension", "exec", "x"]), "未知 gh 子命令应默认拦截"
  end

  def test_apply_mode_allows_writes
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    refute runner.dry_run?
  end

  # 断言子进程真的被调用，而不是只看 calls 记录（记录在拦截前就写了）。
  def test_write_authorization_is_scoped
    add = ["gh", "issue", "edit", "39", "--repo", "o/r", "--add-label", "agent:in-progress"]
    merge = ["gh", "pr", "merge", "5"]
    executed = []

    Open3.singleton_class.alias_method(:__orig_capture3, :capture3)
    Open3.define_singleton_method(:capture3) do |*argv, **_opts|
      executed << argv
      ["", "", Struct.new(:success?).new(true)]
    end

    begin
      runner = SebasAgents::CommandRunner.new(dry_run: true)
      runner.capture(*add)
      runner.capture(*merge)
      assert_empty executed, "dry-run 不得真正执行写命令"

      runner.with_write(:add_label) { runner.capture(*add) }
      assert_equal [add], executed, "授权后 add-label 必须真实执行"

      runner.with_write(:add_label) { runner.capture(*merge) }
      assert_empty executed.select { |c| c.include?("merge") }, "授权 add-label 不应放行 merge"

      runner.capture(*add)
      assert_equal 1, executed.count { |c| c.include?("--add-label") }, "离开授权后恢复拦截"
    ensure
      Open3.singleton_class.alias_method(:capture3, :__orig_capture3)
    end
  end

  # 重试耗尽后，错误必须带 command 与 stderr，否则上游无法定位。
  def test_retry_exhaustion_keeps_command_context
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    calls = 0
    runner.define_singleton_method(:with_retry) do |&block|
      block.call
    end
    runner.singleton_class.send(:remove_method, :with_retry)
    runner.define_singleton_method(:with_retry) do
      calls += 1
      SebasAgents::CommandRunner::Result.new(stdout: "", stderr: "unexpected EOF\n",
        status: Struct.new(:success?).new(false))
    end
    assert_raises(SebasAgents::CommandError) { runner.run!("gh", "api", "x") }
    error = begin
      runner.run!("gh", "api", "x")
    rescue SebasAgents::CommandError => e
      e
    end
    assert_equal ["gh", "api", "x"], error.command
    assert_includes error.stderr.to_s, "EOF"
    assert_includes error.message, "gh api x"
  end
end


class ClosedIssueLabelTest < Minitest::Test
  include SnapshotHelpers

  def test_closed_issue_with_stale_label_is_not_active_claim
    data = snapshot(issues: [
      issue(1, body: automation, labels: ["agent:in-progress"], state: "CLOSED", state_reason: "COMPLETED"),
      issue(2, body: automation(order: [4, 2]))
    ])
    assert_equal "claim_issue", select(data).action
  end
end
