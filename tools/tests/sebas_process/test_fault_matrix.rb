# frozen_string_literal: true

# 故障矩阵覆盖（M4x-Parallel-WP3，#221 §5；续篇 §3 的 F1–F15）。
#
# 只测**纯函数可判定**的判据。F13（main CI 被取消）与 F14 的跨机部分需要真实
# 远端时序，其处置写在 docs/design/process/merge-queue.md，不在本文件伪造。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class FaultMatrixTest < Minitest::Test
  include SnapshotHelpers

  def pr(number: 50, issue: 1, state: "OPEN", merged: false, base: "main",
    head: "sha", checks: [], threads: [], files: nil)
    {
      "number" => number, "head_ref_name" => "feat/#{issue}", "base_ref_name" => base,
      "head_sha" => head, "state" => state, "merged" => merged,
      "merge_state_status" => "CLEAN", "checks" => checks,
      "closing_issues" => [issue], "review_threads" => threads, "files" => files
    }
  end

  def snap(issues: [], prs: [], capacity: nil)
    data = snapshot(issues: issues, pull_requests: prs)
    data["capacity"] = capacity if capacity
    SebasAgents::Model::Snapshot.from_hash(data)
  end

  def view(snapshot, records)
    SebasAgents::Policy::Selection.plan(snapshot, records: records)
  end

  # --- F14：越界检测 ---

  def test_in_scope_changes_pass
    scope = SebasAgents::Policy::Scope
    assert_nil scope.violations([{"filename" => "src/store/x.cr"}], ["src/"])
  end

  def test_out_of_scope_changes_reported
    scope = SebasAgents::Policy::Scope
    violation = scope.violations(
      [{"filename" => "src/store/x.cr"}, {"filename" => "docs/a.md"}], ["src/"])
    refute_nil violation
    assert_includes violation, "docs/a.md"
  end

  # 缺 file 清单或租约缺 scope → 不可判定，按越界处理（fail-closed）。
  def test_missing_inputs_fail_closed
    scope = SebasAgents::Policy::Scope
    refute_nil scope.violations(nil, ["src/"])
    refute_nil scope.violations([{"filename" => "src/x"}], nil)
  end

  # PR 越界 → 本卡转 needs_human 且不推进合并。
  def test_out_of_scope_pr_goes_needs_human
    snapshot = snap(
      issues: [issue(1, body: automation(scope: ["src/store/"]), status: "In progress")],
      prs: [pr(files: [{"filename" => "docs/leak.md"}])],
      capacity: 2
    )
    result = view(snapshot, [{"issue" => 1, "phase" => "claimed", "branch" => "feat/1", "pr" => 50}])
    assert_equal "needs_human", result.next_action
    assert_includes result.excluded.first["reason"], "越界"
  end

  # 快照未取 files 时不在这里判越界（交给 verify merge --pre 的路径检查）。
  def test_unknown_files_does_not_block_here
    snapshot = snap(
      issues: [issue(1, body: automation(scope: ["src/"]), status: "In progress")],
      prs: [pr(files: nil)],
      capacity: 2
    )
    result = view(snapshot, [{"issue" => 1, "phase" => "claimed", "branch" => "feat/1", "pr" => 50}])
    assert_equal "merge_ready", result.next_action
  end

  # --- F15：合并中途崩溃（phase=merging）---

  def test_merging_record_with_merged_pr_awaits_release
    snapshot = snap(
      issues: [issue(1, body: automation(scope: ["src/"]), status: "In progress")],
      prs: [pr(state: "MERGED", merged: true)],
      capacity: 2
    )
    result = view(snapshot, [{"issue" => 1, "phase" => "merging", "branch" => "feat/1", "pr" => 50}])
    assert_equal "release_ready", result.next_action
    # 命中的是路由分支：动作原因不经过 excluded，取 next_issue 与动作本身即可
    assert_equal 1, result.next_issue
  end

  def test_merging_record_with_open_pr_keeps_going
    snapshot = snap(
      issues: [issue(1, body: automation(scope: ["src/"]), status: "In progress")],
      prs: [pr(files: [{"filename" => "src/x.cr"}])],
      capacity: 2
    )
    result = view(snapshot, [{"issue" => 1, "phase" => "merging", "branch" => "feat/1", "pr" => 50}])
    assert_equal "merge_ready", result.next_action,
      "PR 仍 open 时应从核验重来，而不是当成已完成"
  end

  def test_merging_record_with_wrong_base_is_invalid
    snapshot = snap(
      issues: [issue(1, body: automation(scope: ["src/"]), status: "In progress")],
      prs: [pr(state: "MERGED", merged: true, base: "hotfix/0.2.1")],
      capacity: 2
    )
    result = view(snapshot, [{"issue" => 1, "phase" => "merging", "branch" => "feat/1", "pr" => 50}])
    assert_equal "invalid_plan", result.next_action
    assert_includes result.invalid_reason, "人工核对"
  end

  def test_merging_record_with_closed_unmerged_pr_is_invalid
    snapshot = snap(
      issues: [issue(1, body: automation(scope: ["src/"]), status: "In progress")],
      prs: [pr(state: "CLOSED", merged: false)],
      capacity: 2
    )
    result = view(snapshot, [{"issue" => 1, "phase" => "merging", "branch" => "feat/1", "pr" => 50}])
    assert_equal "invalid_plan", result.next_action
    assert_includes result.invalid_reason, "人工裁决"
  end

  # --- F5：心跳过期 ---

  def test_heartbeat_missing_does_not_report_expired
    Dir.mktmpdir do |dir|
      path = File.join(dir, "1.json")
      File.write(path, JSON.generate({"schema" => 2, "issue" => 1, "phase" => "claimed"}), encoding: "UTF-8")
      record = SebasAgents::RunRecord.new(path: path)
      refute record.heartbeat_expired?(600), "老记录没有心跳字段，不应被判过期"
    end
  end

  def test_heartbeat_older_than_ttl_is_expired
    Dir.mktmpdir do |dir|
      path = File.join(dir, "1.json")
      old = (Time.now.utc - 3600).iso8601
      File.write(path, JSON.generate(
        {"schema" => 2, "issue" => 1, "phase" => "claimed", "last_heartbeat_at" => old}), encoding: "UTF-8")
      record = SebasAgents::RunRecord.new(path: path)
      assert record.heartbeat_expired?(600)
      refute record.heartbeat_expired?(7200)
    end
  end

  def test_heartbeat_write_updates_timestamp
    Dir.mktmpdir do |dir|
      path = File.join(dir, "1.json")
      File.write(path, JSON.generate({"schema" => 2, "issue" => 1, "phase" => "claimed"}), encoding: "UTF-8")
      record = SebasAgents::RunRecord.new(path: path)
      stamp = Time.utc(2026, 1, 1)
      data = record.heartbeat!(now: stamp)
      assert_equal stamp.iso8601, data["last_heartbeat_at"]
      assert_equal stamp.iso8601, JSON.parse(File.read(path))["last_heartbeat_at"]
    end
  end

  def test_malformed_heartbeat_treated_as_expired
    Dir.mktmpdir do |dir|
      path = File.join(dir, "1.json")
      File.write(path, JSON.generate(
        {"schema" => 2, "issue" => 1, "phase" => "claimed", "last_heartbeat_at" => "not-a-time"}),
        encoding: "UTF-8")
      assert SebasAgents::RunRecord.new(path: path).heartbeat_expired?(600),
        "时间戳非法按过期处理（fail-closed）"
    end
  end
end
