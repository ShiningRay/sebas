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
    head: "sha", checks: [], threads: [], files: [{"filename" => "src/x.cr"}])
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

  # 缺 file 清单 → 不可判定，按越界处理（fail-closed）。
  def test_missing_file_list_fails_closed
    assert_includes SebasAgents::Policy::Scope.violations(nil, ["src/"]), "未取回"
  end

  # 租约缺 scope **不算**越界：Q4=A 的「独占容量」在认领侧生效，若这里也判
  # 越界，存量缺 scope 的租约永久 needs_human（不能开新卡也不能合并已有 PR）。
  def test_missing_lease_scope_is_not_a_violation
    assert_nil SebasAgents::Policy::Scope.violations([{"filename" => "src/x"}], nil)
  end

  # 非数组输入不能被 Array() 静默折成空数组：{} 会变成 [] = 零变更 = 放行。
  def test_non_array_files_fail_closed
    scope = SebasAgents::Policy::Scope
    refute_nil scope.violations({}, ["src/"])
    refute_nil scope.violations("src/a.cr", ["src/"])
    refute_nil scope.violations(42, ["src/"])
  end

  # 解析不出路径的条目不能静默跳过：无从判定即按越界计。
  def test_unparsable_entry_fails_closed
    scope = SebasAgents::Policy::Scope
    refute_nil scope.violations([{"patch" => "@@"}], ["src/"])
    refute_nil scope.violations([{}], ["src/"])
  end

  # 重命名的原路径也要在 scope 内：把别人的文件搬走同样是越界。
  def test_rename_previous_filename_is_checked
    scope = SebasAgents::Policy::Scope
    violation = scope.violations(
      [{"filename" => "src/store/new.cr", "previous_filename" => "docs/old.md"}], ["src/"])
    refute_nil violation
    assert_includes violation, "docs/old.md"

    # 两个路径都在 scope 内则放行
    assert_nil scope.violations(
      [{"filename" => "src/store/new.cr", "previous_filename" => "src/store/old.cr"}], ["src/"])
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

  # 快照未取 files 也判不可判定 → needs_human。从而不把「没取到」当成「没违规」。
  # 真实快照对 open PR 一定取 files，所以这条只影响离线夹具与提案快照路径。
  def test_unknown_files_goes_needs_human
    snapshot = snap(
      issues: [issue(1, body: automation(scope: ["src/"]), status: "In progress")],
      prs: [pr(files: nil)],
      capacity: 2
    )
    result = view(snapshot, [{"issue" => 1, "phase" => "claimed", "branch" => "feat/1", "pr" => 50}])
    assert_equal "needs_human", result.next_action
    assert_includes result.excluded.first["reason"], "无法判定越界"
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

  # 队列自己追加 CHANGELOG.md 后，该文件出现在 pr.files 里不算 worker 越界——
  # 否则合法 PR 会被队列自己的动作挡成 needs_human。
  def test_queue_owned_changelog_does_not_count_as_violation
    snapshot = snap(
      issues: [issue(1, body: automation(scope: ["src/"]), status: "In progress")],
      prs: [pr(files: [{"filename" => "src/x.cr"}, {"filename" => "CHANGELOG.md"}])],
      capacity: 2
    )
    result = view(snapshot, [{"issue" => 1, "phase" => "claimed", "branch" => "feat/1", "pr" => 50}])
    assert_equal "merge_ready", result.next_action, "队列追加的 CHANGELOG.md 不是越界"
  end

  # 解析不出路径的条目不能被剔除过滤器当成队列自有文件删掉——
  # `[].all?` 恒真会删掉它，剩下的空清单被当成「零变更」放行。
  def test_unparsable_entry_survives_queue_owned_filter
    snapshot = snap(
      issues: [issue(1, body: automation(scope: ["src/"]), status: "In progress")],
      prs: [pr(files: [{"filename" => "src/x.cr"}, {}])],
      capacity: 2
    )
    result = view(snapshot, [{"issue" => 1, "phase" => "claimed", "branch" => "feat/1", "pr" => 50}])
    assert_equal "needs_human", result.next_action, "解析不出路径的条目必须仍判不可判定"
    assert_includes result.excluded.first["reason"], "解析不出路径"
  end

  # scope 外的**其他**文件仍然算越界：剔除只针对队列自有路径。
  def test_foreign_file_still_counts_outside_queue_owned
    snapshot = snap(
      issues: [issue(1, body: automation(scope: ["src/"]), status: "In progress")],
      prs: [pr(files: [{"filename" => "src/x.cr"}, {"filename" => "Makefile"}])],
      capacity: 2
    )
    result = view(snapshot, [{"issue" => 1, "phase" => "claimed", "branch" => "feat/1", "pr" => 50}])
    assert_equal "needs_human", result.next_action
  end

  # 卡片被人工以 completed 关闭、但 PR 仍 open：不许被 settled 判成 release_ready。
  def test_completed_issue_with_open_merging_pr_is_invalid
    snapshot = snap(
      issues: [issue(1, body: automation(scope: ["src/"]), state: "CLOSED",
        state_reason: "COMPLETED")],
      prs: [pr(files: [{"filename" => "src/x.cr"}])],
      capacity: 2
    )
    result = view(snapshot, [{"issue" => 1, "phase" => "merging", "branch" => "feat/1", "pr" => 50}])
    assert_equal "invalid_plan", result.next_action,
      "PR 未合并时不能因卡已 completed 就给 release_ready"
    assert_includes result.invalid_reason, "仍 open"
  end

  # base 缺失不构成放行理由：目标分支是安全边界，缺失即不可判定。
  def test_merging_record_with_missing_base_is_invalid
    snapshot = snap(
      issues: [issue(1, body: automation(scope: ["src/"]), status: "In progress")],
      prs: [pr(state: "MERGED", merged: true, base: nil)],
      capacity: 2
    )
    result = view(snapshot, [{"issue" => 1, "phase" => "merging", "branch" => "feat/1", "pr" => 50}])
    assert_equal "invalid_plan", result.next_action
    assert_includes result.invalid_reason, "不可判定"
  end

  # 多条 merging 记录必须逐条对账：只取第一条会漏掉后面的那条。
  def test_second_merging_record_is_reconciled_when_first_is_inconclusive
    snapshot = snap(
      issues: [
        issue(1, body: automation(scope: ["src/store/"]), status: "In progress"),
        issue(2, body: automation(scope: ["src/keys/"]), status: "In progress")
      ],
      prs: [
        # 第一条：PR 仍 open → reconcile_merging 返回 nil，不能就此结束
        pr(number: 50, issue: 1, files: [{"filename" => "src/store/x.cr"}]),
        # 第二条：已合并 → 必须被对账到
        pr(number: 51, issue: 2, state: "MERGED", merged: true, files: [{"filename" => "src/keys/y.cr"}])
      ],
      capacity: 2
    )
    result = view(snapshot, [
      {"issue" => 1, "phase" => "merging", "branch" => "feat/1", "pr" => 50},
      {"issue" => 2, "phase" => "merging", "branch" => "feat/2", "pr" => 51}
    ])
    assert_equal "release_ready", result.next_action, "第二条 merging 记录不能被漏掉"
    assert_equal 2, result.next_issue
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

  # 空字符串：字段存在但读不出时间，按过期处理（与「字段缺失」区分）。
  def test_empty_heartbeat_treated_as_expired
    Dir.mktmpdir do |dir|
      path = File.join(dir, "1.json")
      File.write(path, JSON.generate(
        {"schema" => 2, "issue" => 1, "phase" => "claimed", "last_heartbeat_at" => ""}),
        encoding: "UTF-8")
      assert SebasAgents::RunRecord.new(path: path).heartbeat_expired?(600),
        "字段存在但为空，按过期处理"
    end
  end

  # 活跃持有者（pid 存活）→ 跳过本次写入，且不删别人的锁。
  def test_heartbeat_skips_when_lock_held_by_live_process
    Dir.mktmpdir do |dir|
      path = File.join(dir, "1.json")
      original = {"schema" => 2, "issue" => 1, "phase" => "claimed"}
      File.write(path, JSON.generate(original), encoding: "UTF-8")
      # 用当前进程 pid：一定存活
      File.write("#{path}.lock", Process.pid.to_s)

      result = SebasAgents::RunRecord.new(path: path).heartbeat!(now: Time.utc(2026, 1, 1))
      assert_nil result, "锁被活跃进程持有时跳过心跳"
      assert_equal original, JSON.parse(File.read(path))
      assert File.exist?("#{path}.lock"), "别人持有的锁不能被删"
    end
  end

  # 残留锁（持有者已退出）→ 接管并完成心跳。否则一次崩溃就让心跳永久失效。
  def test_heartbeat_takes_over_stale_lock
    Dir.mktmpdir do |dir|
      path = File.join(dir, "1.json")
      File.write(path, JSON.generate({"schema" => 2, "issue" => 1, "phase" => "claimed"}), encoding: "UTF-8")
      # 几乎不可能存在的 pid
      File.write("#{path}.lock", "999999")

      stamp = Time.utc(2026, 1, 1)
      data = SebasAgents::RunRecord.new(path: path).heartbeat!(now: stamp)
      refute_nil data, "残留锁必须能被接管"
      assert_equal stamp.iso8601, JSON.parse(File.read(path))["last_heartbeat_at"]
      refute File.exist?("#{path}.lock")
    end
  end

  # 读不到 pid（刚创建、还没写入）→ 按活跃处理，保守不删。
  def test_heartbeat_treats_empty_lock_pid_as_active
    Dir.mktmpdir do |dir|
      path = File.join(dir, "1.json")
      File.write(path, JSON.generate({"schema" => 2, "issue" => 1, "phase" => "claimed"}), encoding: "UTF-8")
      File.write("#{path}.lock", "")

      assert_nil SebasAgents::RunRecord.new(path: path).heartbeat!(now: Time.utc(2026, 1, 1))
      assert File.exist?("#{path}.lock")
    end
  end

  def test_heartbeat_releases_lock_after_write
    Dir.mktmpdir do |dir|
      path = File.join(dir, "1.json")
      File.write(path, JSON.generate({"schema" => 2, "issue" => 1, "phase" => "claimed"}), encoding: "UTF-8")
      SebasAgents::RunRecord.new(path: path).heartbeat!(now: Time.utc(2026, 1, 1))
      refute File.exist?("#{path}.lock"), "写完必须释放锁"
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
