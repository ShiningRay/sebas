# frozen_string_literal: true

# 选卡调度：order 最小优先、暂停卡整轮停手、认领/续跑、并行轨回退。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class SelectionSchedulingTest < Minitest::Test
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

  def test_tracking_manual_and_design_excluded
    data = snapshot(issues: [
      issue(1, body: automation(kind: "tracking")),
      issue(2, body: automation(kind: "manual")),
      issue(4, body: automation(kind: "design", order: [0])),
      issue(3, body: automation(order: [4]))
    ])
    action = select(data)
    assert_equal 3, action.issue
    reasons = action.excluded.map { |item| item["reason"] }
    assert_includes reasons, "kind=design"
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

  def test_own_pull_request_resumes_before_new_card
    pr = {
      "number" => 50, "head_ref_name" => "feat/1", "state" => "OPEN",
      "merge_state_status" => "BEHIND", "checks" => [],
      "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(
      issues: [issue(1, body: automation, status: "In progress"), issue(2, body: automation(order: [4, 2]))],
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
      issues: [issue(1, body: automation, status: "In progress")],
      pull_requests: [pr]
    )
    assert_equal "wait", select(data, record: {"issue" => 1, "pr" => 50}).action
  end

  # 第三方审阅的 check run 只是「本轮审阅进行中」，不进分支保护的必需检查。
  # 把它算作 pending 会让 selector 报「等待 CI」，而合并条件根本不看它。
  # 用非 CLEAN 状态，避免落到 select_action 的 CLEAN 短路分支从而测不到判定。
  def test_pending_advisory_check_is_not_reported_as_ci_wait
    pr = {
      "number" => 50, "state" => "OPEN", "merge_state_status" => "BLOCKED",
      "checks" => [
        {"name" => "spec / ubuntu-latest", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
        {"name" => "CodeRabbit", "status" => "IN_PROGRESS", "conclusion" => nil}
      ],
      "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(
      issues: [issue(1, body: automation, status: "In progress")],
      pull_requests: [pr]
    )
    action = select(data, record: {"issue" => 1, "pr" => 50})
    assert_equal "wait", action.action
    refute_includes action.reason, "等待 CI", "advisory 进度不应被报成等 CI"
    assert_includes action.reason, "BLOCKED"
  end

  # 对照：真正的门禁检查未完成时仍报「等待 CI」。
  def test_pending_gate_check_is_reported_as_ci_wait
    pr = {
      "number" => 50, "state" => "OPEN", "merge_state_status" => "BLOCKED",
      "checks" => [
        {"name" => "spec / ubuntu-latest", "status" => "IN_PROGRESS", "conclusion" => nil},
        {"name" => "CodeRabbit", "status" => "IN_PROGRESS", "conclusion" => nil}
      ],
      "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(
      issues: [issue(1, body: automation, status: "In progress")],
      pull_requests: [pr]
    )
    assert_includes select(data, record: {"issue" => 1, "pr" => 50}).reason, "等待 CI"
  end

  # 只豁免「进行中」：advisory 已完成却是失败结论时仍按失败处理
  # （历史 CodeRabbit 服务故障 CANCELLED 需人工裁决，不能静默放过）。
  def test_failed_advisory_check_still_blocks_merge
    pr = {
      "number" => 50, "state" => "OPEN", "merge_state_status" => "UNKNOWN",
      "checks" => [
        {"name" => "spec / ubuntu-latest", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
        {"name" => "CodeRabbit", "status" => "COMPLETED", "conclusion" => "CANCELLED"}
      ],
      "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(
      issues: [issue(1, body: automation, status: "In progress")],
      pull_requests: [pr]
    )
    action = select(data, record: {"issue" => 1, "pr" => 50})
    assert_equal "resume_pr", action.action
    assert_includes action.reason, "失败检查"
  end

  # advisory 的未知状态不豁免：豁免只认 queued/in_progress，其余留在 pending 里
  # 继续按「等待 CI」处理，而不是因为落不进任何分支就静默放行。
  def test_unknown_advisory_status_still_reported_as_ci_wait
    pr = {
      "number" => 50, "state" => "OPEN", "merge_state_status" => "BLOCKED",
      "checks" => [
        {"name" => "spec / ubuntu-latest", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
        {"name" => "CodeRabbit", "status" => "BOGUS", "conclusion" => nil}
      ],
      "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(
      issues: [issue(1, body: automation, status: "In progress")],
      pull_requests: [pr]
    )
    assert_includes select(data, record: {"issue" => 1, "pr" => 50}).reason, "等待 CI"
  end

  def test_claiming_interruption_resumes
    data = snapshot(issues: [issue(1, body: automation, status: "In progress")])
    action = select(data, record: {"issue" => 1, "phase" => "claiming"})
    assert_equal "resume_issue", action.action
    assert_includes action.reason, "claiming"
  end

  def test_paused_with_resume_returns_resume
    data = snapshot(issues: [issue(1, body: automation, labels: %w[needs:human agent:resume], status: "In progress")])
    action = select(data, record: {"issue" => 1, "phase" => "paused"})
    assert_equal "resume_issue", action.action
    assert_includes action.reason, "agent:resume"
  end

  def test_local_remote_conflict_is_invalid
    data = snapshot(issues: [issue(1, body: automation, status: "In progress")])
    assert_equal "invalid_plan", select(data, record: {"issue" => 99}).action
  end

  # released 记录不占认领位：unclaim 成功后本地仍留着旧 issue 号，
  # 远端随后认领别的卡时不得报假冲突（否则 next 永久堵死）。
  def test_released_record_does_not_conflict_with_new_claim
    data = snapshot(
      issues: [issue(1, body: automation, status: "In progress")],
      pull_requests: [{
        "number" => 50, "head_ref_name" => "feat/1", "state" => "OPEN",
        "merge_state_status" => "CLEAN", "checks" => [],
        "closing_issues" => [1], "review_threads" => []
      }]
    )
    action = select(data, record: {"issue" => 99, "phase" => "released"})
    refute_equal "invalid_plan", action.action, "released 记录不应与远端认领冲突：#{action.reason}"
  end

  # 反向守卫：仍在持有的 phase 遇到不同认领必须继续判冲突，不能因上一条放宽而漏判。
  # 必须同时断言原因含「冲突」——否则 claiming/aborted 等会经 resume_claimed /
  # reconcile_aborted 返回同样 invalid_plan 的动作，把冲突检查的回归掩盖掉。
  def test_holding_phases_still_conflict_with_other_claim
    data = snapshot(issues: [issue(1, body: automation, status: "In progress")])
    %w[claiming claimed paused aborted].each do |phase|
      action = select(data, record: {"issue" => 99, "phase" => phase})
      assert_equal "invalid_plan", action.action, "phase=#{phase} 必须判冲突"
      assert_includes action.reason, "冲突",
        "phase=#{phase} 必须因本地记录与远端认领冲突而判定，实际：#{action.reason}"
    end
  end

  # released 记录整条降级为「无记录」：远端认领别的卡时不得报假冲突，
  # 也不得把该记录的 worktree 当作新认领的续做状态。
  # 注意：降级后若远端确实有认领而本地无记录，会走 resume_claimed 的
  # 「已认领但缺本地运行记录」fail-closed 分支——那是既有正确行为，不是本缺陷。
  def test_released_record_is_not_reused_as_resume_state
    data = snapshot(issues: [issue(1, body: automation, status: "In progress")])
    action = select(data, record: {"issue" => 99, "phase" => "released", "worktree" => "/tmp/old-99"})

    refute_includes action.reason.to_s, "与远端认领",
      "released 记录不得与远端认领判假冲突：#{action.reason}"
    refute_includes action.reason.to_s, "/tmp/old-99",
      "released 记录的 worktree 不得被当作续做状态"
    assert_includes action.reason.to_s, "缺本地运行记录",
      "降级后应走既有的「认领但无本地记录」fail-closed 分支：#{action.reason}"
  end

  def test_handoff_release_when_no_open_issues
    data = snapshot(issues: [], milestones: [
      {"number" => 2, "title" => "M4", "state" => "open", "order" => "4", "track" => "main", "open_issues" => 0, "description" => "order: 4
track: main
"}
    ])
    assert_equal "handoff_release", select(data).action
  end

  def test_falls_back_to_parallel_track_when_main_blocked
    data = snapshot(
      issues: [
        # 主线只有 tracking 卡（不可认领）→ main 评估为 blocked
        issue(1, body: automation(kind: "tracking", order: [4, 1])),
        # 并行轨有可执行卡
        issue(9, milestone: 1, body: automation(order: [4, 1]))
      ],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 1),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
      ]
    )
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 9, action.issue
    assert_equal 1, action.milestone
    assert_includes action.reason, "并行轨"
  end

  # 主线仍有就绪卡时，并行轨不得抢位。
  def test_main_ready_card_beats_parallel_track
    data = snapshot(
      issues: [
        issue(1, body: automation(order: [4, 1])),
        issue(9, milestone: 1, body: automation(order: [4, 1]))
      ],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 1),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
      ]
    )
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 1, action.issue
    assert_equal 2, action.milestone
  end

  # 主线清空要进发版门禁，不能被并行轨截走。
  def test_handoff_release_is_not_hijacked_by_parallel_track
    data = snapshot(
      issues: [issue(9, milestone: 1, body: automation(order: [4, 1]))],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 0),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
      ]
    )
    assert_equal "handoff_release", select(data).action
  end

  # 并行轨也无卡可做时，仍报主线的 blocked，不吞掉原始原因。
  def test_blocked_reported_when_parallel_track_also_empty
    data = snapshot(
      issues: [issue(1, body: automation(kind: "manual", order: [4, 1]))],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 1),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
      ]
    )
    action = select(data)
    assert_equal "blocked", action.action
    assert_equal 2, action.milestone
    assert_includes action.reason, "active 主线"
  end

  # 配置错误必须暴露，不能靠切到并行轨掩盖。
  def test_invalid_main_is_not_masked_by_parallel_track
    data = snapshot(
      issues: [
        issue(1, body: automation(order: [4, 1]), blocked_by: [99]),
        issue(9, milestone: 1, body: automation(order: [4, 1]))
      ],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 1),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
      ]
    )
    action = select(data)
    assert_equal "invalid_plan", action.action
  end

# 并行轨自己的 invalid_plan 也不能被跳过：它同样是配置错误。
def test_invalid_parallel_track_is_reported_not_skipped
  data = snapshot(
    issues: [
      issue(1, body: automation(kind: "manual", order: [4, 1])),
      # 并行轨依赖快照外的前置 → validate_graph 判非法
      issue(9, milestone: 1, body: automation(order: [4, 1]), blocked_by: [99])
    ],
    milestones: [
      milestone(number: 2, order: "4", track: "main", open_issues: 1),
      milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
    ]
  )
  action = select(data)
  assert_equal "invalid_plan", action.action
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
      issue(1, body: automation, status: "In progress"),
      issue(2, body: automation, status: "In progress")
    ])
    assert_equal "invalid_plan", select(data).action
  end
end
