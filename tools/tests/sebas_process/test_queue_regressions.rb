# frozen_string_literal: true

# 本轮 CodeRabbit 意见的回归测试（#221 分片 2）。
#
# 这些都是「会不会做错事」的判定，比性能重要：漏判会导致带 marker 的 PR
# 永远不入队、显式记录被当成异机租约、或已合并卡拖死另一张在途卡。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class QueueRegressionsTest < Minitest::Test
  include SnapshotHelpers

  MQ = SebasAgents::MergeQueue

  # --- CHANGELOG 引用匹配的编号边界 ---

  # `/pull/501` 不能被当成 `#50` 的条目，否则 PR 50 会漏追加直接合并。
  def test_pull_url_needs_number_boundary
    refute MQ.entry_for?("- 条目 (https://github.com/o/r/pull/501)", 50)
    assert MQ.entry_for?("- 条目 (https://github.com/o/r/pull/50)", 50)
    assert MQ.entry_for?("- 条目 (#50)", 50)
    refute MQ.entry_for?("- 条目 (#501)", 50)
    # 行尾与标点都算边界
    assert MQ.entry_for?("- 见 /pull/50。", 50)
  end

  # --- 追加是幂等的，且位置在 [Unreleased] 段内 ---

  def test_append_entries_inserts_under_unreleased
    base = "# Title\n\n## [Unreleased]\n\n- 旧条目 (#10)\n\n## [0.2.0]\n"
    out = MQ.append_entries(base, ["- 新条目 (#50)"], 50)
    assert_includes out, "- 新条目 (#50)"
    # 新条目必须落在 [Unreleased] 与 [0.2.0] 之间
    assert_operator out.index("- 新条目 (#50)"), :<, out.index("## [0.2.0]")
    assert_operator out.index("## [Unreleased]"), :<, out.index("- 新条目 (#50)")
  end

  def test_append_entries_is_idempotent
    base = "## [Unreleased]\n\n- 旧条目 (#10)\n"
    once = MQ.append_entries(base, ["- 新条目 (#50)"], 50)
    twice = MQ.append_entries(once, ["- 新条目 (#50)"], 50)
    assert_equal once, twice
  end

  def test_append_entries_requires_unreleased_section
    assert_raises(SebasAgents::InvalidPlan) do
      MQ.append_entries("# Title\n\n## [0.2.0]\n", ["- 新条目 (#50)"], 50)
    end
  end

  # --- scope 归一的重复前缀 ---

  # `././src/` 只剥一次会剩 `./src/`，与 `src/` 前缀互不包含 → 漏判冲突。
  def test_scope_normalize_strips_repeated_dot_prefix
    scope = SebasAgents::Policy::Scope
    assert_equal ["src/"], scope.normalize(["././src/"])
    assert scope.conflict?(scope.normalize(["././src/"]), ["src/"])
    refute_nil scope.blocking_lease(scope.normalize(["././src/"]), [{issue: 9, scope: ["src/"]}])
  end

  # --- Evidence 未升级时队列不许提前合下一张 ---

  def test_pending_evidence_blocks_queue
    queue = MQ.plan([], SebasAgents::Model::Snapshot.from_hash(snapshot(issues: [], pull_requests: [])),
      pending_evidence: [7])
    assert_equal 7, queue.head
    assert_equal "evidence", queue.step
    assert_includes queue.blocked_by, "Evidence 未升级"
  end

  def test_no_pending_evidence_keeps_queue_moving
    queue = MQ.plan([], SebasAgents::Model::Snapshot.from_hash(snapshot(issues: [], pull_requests: [])),
      pending_evidence: [])
    assert queue.empty?
  end

  # --- 已合并待释放的记录不得判成所有权冲突 ---

  def test_merged_but_unreleased_record_does_not_block_other_lease
    merged_pr = {
      "number" => 60, "state" => "MERGED", "merged" => true, "base_ref_name" => "main",
      "head_ref_name" => "feat/1", "checks" => [], "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(
      issues: [
        issue(1, body: automation(scope: ["src/store/"]), state: "CLOSED", state_reason: "completed"),
        issue(2, body: automation(scope: ["src/keys/"]), status: "In progress")
      ],
      pull_requests: [merged_pr],
      capacity: 2
    )
    view = SebasAgents::Policy::Selection.plan(
      SebasAgents::Model::Snapshot.from_hash(data),
      records: [
        {"issue" => 1, "phase" => "claimed", "branch" => "feat/1", "pr" => 60},
        {"issue" => 2, "phase" => "claimed", "branch" => "feat/2"}
      ])
    refute_equal "invalid_plan", view.next_action,
      "合并后未 unclaim 是正常中间态，不该连带另一张判 invalid"

    # 另一张在途卡仍能拿到动作
    lease2 = view.leases.find { |lease| lease.issue == 2 }
    refute_nil lease2
    assert_equal "resume_issue", lease2.action
  end

  # 真的所有权冲突（远端有别的认领）仍然 fail-closed。
  def test_real_ownership_conflict_still_invalid
    data = snapshot(
      issues: [issue(1, body: automation(scope: ["src/"]), status: "In progress")],
      capacity: 2
    )
    view = SebasAgents::Policy::Selection.plan(
      SebasAgents::Model::Snapshot.from_hash(data),
      records: [{"issue" => 99, "phase" => "claimed"}])
    assert_equal "invalid_plan", view.next_action
    assert_includes view.invalid_reason, "冲突"
  end
end
