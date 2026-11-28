# frozen_string_literal: true

# 只读多候选视图 plan（M4x-Parallel-WP1，#218）：与 next 同快照同策略，
# 返回全部就绪候选与带枚举码的排除集；首选与 next 恒等。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

require "socket"

class PlanCommandTest < Minitest::Test
  include SnapshotHelpers
  include CliHelpers

  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = SebasAgents::CLI.new(out: out, err: err).run(argv)
    [status, out.string, err.string]
  end

  def test_single_candidate_is_selected_and_identical_to_next
    data = snapshot(issues: [issue(1, body: automation(order: [4, 1]))])
    view = plan(data)
    assert_equal 1, view.ready.size
    assert_equal 1, view.next_issue
    assert_equal "claim_issue", view.next_action
    assert_nil view.invalid_reason
  end

  def test_multiple_candidates_ordered_and_first_identical_to_next
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 2])),
      issue(2, body: automation(order: [4, 1])),
      issue(3, body: automation(order: [4, 3]))
    ])
    view = plan(data)
    assert_equal [2, 1, 3], view.ready.map(&:number)
    assert_equal "claim_issue", view.next_action
    # 首选恒等：next 选出的 issue 必须等于 plan.candidates[0]
    assert_equal select(data).issue, view.ready.first.number
    assert_equal view.next_issue, view.ready.first.number
  end

  def test_dependency_unmet_excluded_with_enum_code
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1], depends_on: [2], prose: "#2"), blocked_by: [2]),
      issue(2, body: automation(order: [4, 2]))
    ])
    view = plan(data)
    # 依赖卡 #2 本身就绪；被阻塞的只有声明前置的 #1
    assert_equal [2], view.ready.map(&:number)
    row = view.excluded.find { |entry| entry["issue"] == 1 }
    refute_nil row
    assert_equal "depends_on_unmet", row["code"]
    assert_includes row["reason"], "前置 #2"
    assert_equal "claim_issue", view.next_action
    assert_equal 2, view.next_issue
  end

  def test_open_pr_excluded_with_has_pr_code
    pr = {
      "number" => 50, "head_ref_name" => "feat/1", "state" => "OPEN",
      "merge_state_status" => "CLEAN", "checks" => [],
      "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1])),
      issue(2, body: automation(order: [4, 2]))
    ], pull_requests: [pr])
    view = plan(data)
    row = view.excluded.find { |entry| entry["issue"] == 1 }
    refute_nil row
    assert_equal "has_pr", row["code"]
    # 无 PR 关联的卡照常进入候选
    assert_equal [2], view.ready.map(&:number)
  end

  # Q9：needs:human 只作用于本卡。没有其他就绪卡时 plan 报 blocked（不是全局
  # needs_human），暂停卡以枚举码 needs_human 出现在 excluded 里。
  def test_needs_human_card_excluded_with_enum_code
    data = snapshot(issues: [issue(1, body: automation(order: [4, 1]), labels: ["needs:human"])])
    view = plan(data)
    assert_equal [], view.ready
    assert_equal "blocked", view.next_action
    row = view.excluded.find { |entry| entry["issue"] == 1 }
    refute_nil row
    assert_equal "needs_human", row["code"]
  end

  def test_claimed_card_reported_as_already_in_progress
    data = snapshot(issues: [issue(1, body: automation(order: [4, 1]), status: "In progress")])
    view = plan(data, record: {"issue" => 1, "phase" => "claimed", "worktree" => "../w"})
    assert_equal [], view.ready
    assert_equal "resume_issue", view.next_action
    assert_equal "already_in_progress", view.excluded.first["code"]
  end

  def test_parallel_fallback_candidates_identical_to_next
    data = snapshot(
      issues: [
        issue(1, body: automation(kind: "tracking", order: [4, 1])),
        issue(9, milestone: 1, body: automation(order: [4, 1]))
      ],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 1),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
      ]
    )
    view = plan(data)
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal action.issue, view.next_issue
    assert_equal [action.issue], view.ready.map(&:number)
    assert_equal 1, view.milestone
  end

  def test_all_blocked_keeps_main_excluded_and_reports_blocked
    data = snapshot(
      issues: [
        issue(1, body: automation(order: [4, 1], depends_on: [2], prose: "#2"), blocked_by: [2]),
        issue(2, body: automation(order: [4, 2], depends_on: [3], prose: "#3"), blocked_by: [3]),
        # not_planned 不算完成（§2.3）：作为 #2 的前置，阻塞而不判非法
        issue(3, body: automation(order: [4, 3]), state: "CLOSED", state_reason: "not_planned")
      ]
    )
    view = plan(data)
    assert_equal "blocked", view.next_action
    assert_equal [], view.ready
    assert_equal [1, 2], view.excluded.map { |entry| entry["issue"] }
    assert view.excluded.all? { |entry| entry["code"] == "depends_on_unmet" }
  end

  def test_invalid_graph_reported_as_invalid_plan
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1])),
      issue(2, body: automation(order: [4, 1]))
    ])
    view = plan(data)
    assert_equal "invalid_plan", view.next_action
    assert_includes view.invalid_reason, "计划顺序"
  end

  # 验收背压口径（#221 §4）：只数待核验的 merge_ready，不是 open PR 数。
  def test_verifier_queue_depth_counts_only_merge_ready
    mq = SebasAgents::MergeQueue
    leases = [
      SebasAgents::Policy::Routing::LeaseAction.new(issue: 1, action: "merge_ready", reason: "x", pr: 10),
      SebasAgents::Policy::Routing::LeaseAction.new(issue: 2, action: "merge_ready", reason: "x", pr: 11),
      SebasAgents::Policy::Routing::LeaseAction.new(issue: 3, action: "wait", reason: "y", pr: 12),
      SebasAgents::Policy::Routing::LeaseAction.new(issue: 4, action: "needs_human", reason: "z", pr: nil),
      SebasAgents::Policy::Routing::LeaseAction.new(issue: 5, action: "resume_pr", reason: "w", pr: 13)
    ]
    assert_equal 2, mq.verifier_queue_depth(leases), "只有 merge_ready 且带 PR 的才算待验收"
  end

  # CLI 级：离线快照 + JSON 契约字段 + 退出码。
  def test_cli_plan_emits_contract_payload
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 2])),
      issue(2, body: automation(order: [4, 1]))
    ], pull_requests: [
      {"number" => 50, "head_ref_name" => "feat/9", "state" => "OPEN",
       "merge_state_status" => "CLEAN", "checks" => [],
       "closing_issues" => [9], "review_threads" => []}
    ])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["plan", "--snapshot", snap])
      assert_equal 0, status
      payload = JSON.parse(out)
      assert_equal true, payload["ok"]
      assert_equal 1, payload["capacity"]
      # 该 PR 的卡 #9 不在快照里，队列没有 merge_ready 租约 → 背压为 0。
      # 口径是「待独立核验的 merge_ready 数」，不是 open PR 数。
      assert_equal 0, payload["verifier_queue_depth"]
      assert_equal "claim_issue", payload["next_action"]
      assert_equal 2, payload["next_issue"]
      assert_equal [2, 1], payload["candidates"].map { |c| c["issue"] }
      assert_equal true, payload["candidates"].first["selected"]
      refute payload["candidates"].last["selected"]
      assert_nil payload["candidates"].first["scope_conflict"]
      assert_equal "deadbeef", payload["observed_main"]
      assert payload["excluded"].all? { |row| row.key?("reason") && row.key?("detail") }
    end
  end

  # 容量配置（recovery §5 / Q3）：快照 capacity 贯穿到 plan 输出，
  # capacity_used 为在途卡数；异机在途卡不再把整个视图打成 wait。
  def test_cli_plan_emits_capacity_fields_from_snapshot
    # Q4=A 强制：容量 >1 时两卡都要声明 scope 且不重叠，否则缺 scope 独占容量。
    data = snapshot(issues: [
      issue(1, body: automation(scope: ["src/store/"]), status: "In progress"),
      issue(2, body: automation(order: [4, 2], scope: ["src/keys/"]))
    ], capacity: 2)
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["plan", "--snapshot", snap])
      assert_equal 0, status
      payload = JSON.parse(out)
      assert_equal 2, payload["capacity"]
      assert_equal 2, payload["capacity_limit"]
      assert_operator payload["capacity_used"], :<=, payload["capacity_limit"]
      assert_equal 1, payload["capacity_used"]
      assert_equal "claim_issue", payload["next_action"]
    end
  end

  # 迁移期容量恒 1（Q10=B）：v1 遗留记录仍活动时有效容量钳回 1；
  # released 遗留不构成约束。钳制只影响判定输出，不改快照文件。
  def test_plan_capacity_clamped_during_migration_window
    data = snapshot(issues: [issue(1, body: automation)], capacity: 2)
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      sebas_dir = File.join(dir, ".sebas-agent")
      Dir.mkdir(sebas_dir)
      legacy = File.join(sebas_dir, "run.json")

      File.write(legacy, JSON.generate({"issue" => 9, "phase" => "claimed", "schema" => 1}), encoding: "UTF-8")
      Dir.chdir(dir) do
        status, out, = run_cli(["plan", "--snapshot", snap])
        assert_equal 0, status
        assert_equal 1, JSON.parse(out)["capacity"]
      end

      File.write(legacy, JSON.generate({"issue" => 9, "phase" => "released", "schema" => 1}), encoding: "UTF-8")
      Dir.chdir(dir) do
        status, out, = run_cli(["plan", "--snapshot", snap])
        assert_equal 0, status
        assert_equal 2, JSON.parse(out)["capacity"]
      end
    end
  end

  def test_cli_plan_invalid_plan_exits_refused
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1])),
      issue(2, body: automation(order: [4, 1]))
    ])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["plan", "--snapshot", snap])
      assert_equal 1, status
      payload = JSON.parse(out)
      assert_equal false, payload["ok"]
      assert_equal "invalid_plan", payload["next_action"]
      assert_includes payload["invalid_reason"], "计划顺序"
    end
  end

end
