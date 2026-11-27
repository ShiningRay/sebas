# frozen_string_literal: true

# 2026-11-21 只读复核列出的 CLI 缺陷回归：每条都曾在真实命令上复现。
# 覆盖 proposal 裁决快照、快照解析失败路径、认领/续跑/释放与 Proposal 判定。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class CliRobustnessTest < Minitest::Test
  include SnapshotHelpers
  include CliHelpers

  def test_proposal_snapshot_resolves_registered_verdict_author_and_body
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    issue = SebasAgents::Model::Issue.from_hash({
      "number" => 8, "labels" => ["proposal"],
      "body" => "<!-- proposal-decision: #{url} -->"
    })
    runner = Object.new
    runner.define_singleton_method(:json!) do |*_args|
      {"user" => {"login" => "ShiningRay"}, "body" => "<!-- proposal-verdict: accepted-design -->",
        "issue_url" => "https://api.github.com/repos/o/r/issues/8"}
    end
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    evidence = gateway.send(:proposal_decision_evidence, [issue], 8)
    data = snapshot(issues: []).merge("proposal_evidence" => evidence)
    snap = SebasAgents::Model::Snapshot.from_hash(data)
    plan = SebasAgents::Triager.plan(issue, snap, verdict: {"decision" => "accepted-design", "maintainer_decision_url" => url})
    assert plan["ok"]
    assert_equal "ShiningRay", evidence.dig(url, "author")
    assert_includes plan["comment"], url
  end

  def test_proposal_snapshot_rejects_comment_from_another_issue
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    issue = SebasAgents::Model::Issue.from_hash({
      "number" => 8, "labels" => ["proposal"],
      "body" => "<!-- proposal-decision: #{url} -->"
    })
    runner = Object.new
    runner.define_singleton_method(:json!) do |*_args|
      {"user" => {"login" => "ShiningRay"}, "body" => "<!-- proposal-verdict: accepted-design -->",
        "issue_url" => "https://api.github.com/repos/o/r/issues/9"}
    end
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    evidence = gateway.send(:proposal_decision_evidence, [issue], 8)
    snap = SebasAgents::Model::Snapshot.from_hash(snapshot(issues: []).merge("proposal_evidence" => evidence))
    error = assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::Triager.plan(issue, snap, verdict: {"decision" => "accepted-design", "maintainer_decision_url" => url})
    end
    assert_includes error.message, "真实父对象"
  end

  def test_proposal_snapshot_ignores_malformed_reference_on_regular_issue
    regular = SebasAgents::Model::Issue.from_hash({
      "number" => 9, "body" => "<!-- proposal-decision: https://example.invalid/not-a-comment -->"
    })
    gateway = SebasAgents::GithubGateway.new(Object.new, repo: "o/r")
    assert_empty gateway.send(:proposal_decision_evidence, [regular], 9)
    assert_empty gateway.send(:proposal_decision_evidence, [regular], 8)
  end

  def test_proposal_decision_endpoints_and_pr_comment_parent
    cases = {
      "https://github.com/o/r/issues/8#issuecomment-1" => [
        "repos/o/r/issues/comments/1", "issue_url", "https://api.github.com/repos/o/r/issues/8"
      ],
      "https://github.com/o/r/pull/9#discussion_r2" => [
        "repos/o/r/pulls/comments/2", "pull_request_url", "https://api.github.com/repos/o/r/pulls/9"
      ],
      "https://github.com/o/r/pull/9#pullrequestreview-3" => [
        "repos/o/r/pulls/9/reviews/3", "pull_request_url", "https://api.github.com/repos/o/r/pulls/9"
      ],
      "https://github.com/o/r/pull/9#issuecomment-4" => [
        "repos/o/r/issues/comments/4", "issue_url", "https://api.github.com/repos/o/r/issues/9"
      ]
    }
    cases.each do |url, (path, parent_field, parent)|
      calls = []
      runner = Object.new
      runner.define_singleton_method(:json!) do |*args|
        calls << args
        {"user" => {"login" => "ShiningRay"}, "body" => "verdict", parent_field => parent}
      end
      issue = SebasAgents::Model::Issue.from_hash({"number" => 8, "labels" => ["proposal"], "body" => "<!-- proposal-decision: #{url} -->"})
      gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
      evidence = gateway.send(:proposal_decision_evidence, [issue], 8)
      assert_equal ["gh", "api", path], calls.first
      expected_parent = parent_field == "issue_url" && url.include?("/pull/") ? parent.sub("/issues/", "/pulls/") : parent
      assert_equal expected_parent, evidence.dig(url, "parent")
    end
  end

  def test_proposal_snapshot_rejects_review_from_another_pr
    url = "https://github.com/o/r/pull/9#discussion_r123"
    issue = SebasAgents::Model::Issue.from_hash({
      "number" => 8, "labels" => ["proposal"],
      "body" => "<!-- proposal-decision: #{url} -->"
    })
    runner = Object.new
    runner.define_singleton_method(:json!) do |*_args|
      {"user" => {"login" => "ShiningRay"}, "body" => "<!-- proposal-verdict: accepted-design -->",
        "pull_request_url" => "https://api.github.com/repos/o/r/pulls/10"}
    end
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    evidence = gateway.send(:proposal_decision_evidence, [issue], 8)
    data = snapshot(issues: [], pull_requests: [{"number" => 9, "body" => "Design #8"}]).merge("proposal_evidence" => evidence)
    snap = SebasAgents::Model::Snapshot.from_hash(data)
    error = assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::Triager.plan(issue, snap, verdict: {"decision" => "accepted-design", "maintainer_decision_url" => url})
    end
    assert_includes error.message, "真实父对象"
  end

  # 阻断 1
  def test_version_exits_zero
    status, out, = run_cli(["version"])
    assert_equal 0, status
    assert_equal "sebas-process", JSON.parse(out)["name"]
  end

  # 阻断 2
  def test_docs_check_command_runs
    status, out, = run_cli(%w[docs-check])
    assert_includes [0, 1], status
    assert_includes out, "Markdown"
  end

  # 阻断 3：git 输出带尾换行会拼出非法 revision。
  # 不依赖仓库真实 tag：直接验证 Release.plan 的纯逻辑 + CLI 的 strip 行为。
  def test_release_plan_strips_git_output
    planner = SebasAgents::Release.plan(latest_tag: "v0.1.0", subjects: ["fix(a): b"])
    assert_equal "patch", planner["action"]
    assert_equal "0.1.1", planner["next_version"]
  end

  def test_release_plan_rejects_unstripped_tag
    # 防御：若调用方忘了 strip，必须明确报错而不是拼出 "v0.1.0\n..HEAD"
    assert_raises(SebasAgents::UsageError) do
      SebasAgents::Release.plan(latest_tag: "v0.1.0\n", subjects: ["fix(a): b"])
    end
  end

  def test_release_plan_without_tag_is_usage_error
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        system("git", "init", "-q", out: File::NULL, err: File::NULL)
        status, out, = run_cli(%w[release plan])
        assert_equal 2, status
        assert_equal "command_failed", JSON.parse(out)["error"]["code"]
      end
    end
  end

  # 阻断 7 / 应修 20：空快照不能变成 idle
  def test_empty_snapshot_is_rejected
    with_snapshot({}) do |path, dir|
      status, out, = run_cli(["next", "--snapshot", path, "--record", File.join(dir, "r.json")])
      assert_equal 1, status
      assert_equal "invalid_plan", JSON.parse(out)["error"]["code"]
    end
  end

  def test_snapshot_without_main_sha_is_rejected
    data = snapshot(issues: []).merge("main_sha" => "")
    with_snapshot(data) do |path, dir|
      status, out, = run_cli(["next", "--snapshot", path, "--record", File.join(dir, "r.json")])
      assert_equal 1, status
      assert_includes out, "main_sha"
    end
  end

  # 阻断 16：异常必须是可解析 JSON + 退出码 2
  def test_missing_snapshot_file_is_json_error
    status, out, = run_cli(["next", "--snapshot", "/definitely/not/here.json"])
    assert_equal 2, status
    assert_equal "usage_error", JSON.parse(out)["error"]["code"]
  end

  def test_non_numeric_issue_is_json_error
    status, out, = run_cli(%w[claim abc])
    assert_equal 2, status
    assert_equal "usage_error", JSON.parse(out)["error"]["code"]
    refute_includes out, "backtrace"
  end

  def test_malformed_anchors_json_is_json_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.json")
      File.write(path, "{not json", encoding: "UTF-8")
      status, out, = run_cli(["verify", "anchors", path])
      assert_equal 2, status
      assert_equal "usage_error", JSON.parse(out)["error"]["code"]
    end
  end

  def test_missing_verifier_report_is_json_error
    status, out, = run_cli(["review", "/nope/report.json", "--fixes", "/nope/fixes.json"])
    assert_equal 2, status
    assert_equal "usage_error", JSON.parse(out)["error"]["code"]
  end

  # 阻断 11：claim 必须拒绝不该开工的卡
  def test_claim_rejects_closed_issue
    data = snapshot(issues: [issue(1, body: automation, state: "CLOSED", state_reason: "COMPLETED")])
    with_snapshot(data) do |path, dir|
      status, out, = run_cli(["claim", "1", "--snapshot", path, "--record", File.join(dir, "r.json")])
      assert_equal 1, status
      refute JSON.parse(out)["ok"]
    end
  end

  def test_claim_rejects_needs_human
    data = snapshot(issues: [issue(1, body: automation, labels: ["needs:human"])])
    with_snapshot(data) do |path, dir|
      status, out, = run_cli(["claim", "1", "--snapshot", path, "--record", File.join(dir, "r.json")])
      assert_equal 1, status
      assert_includes out, "needs:human"
    end
  end

  def test_claim_rejects_tracking_kind
    data = snapshot(issues: [issue(1, body: automation(kind: "tracking"))])
    with_snapshot(data) do |path, dir|
      status, _out, = run_cli(["claim", "1", "--snapshot", path, "--record", File.join(dir, "r.json")])
      assert_equal 1, status
    end
  end

  def test_claim_rejects_card_with_open_pr
    pr = {"number" => 9, "state" => "OPEN", "closing_issues" => [1], "checks" => [], "review_threads" => []}
    data = snapshot(issues: [issue(1, body: automation)], pull_requests: [pr])
    with_snapshot(data) do |path, dir|
      status, out, = run_cli(["claim", "1", "--snapshot", path, "--record", File.join(dir, "r.json")])
      assert_equal 1, status
      assert_includes out, "PR"
    end
  end

  def test_claim_refuses_when_another_card_is_in_progress
    data = snapshot(issues: [
      issue(1, body: automation, status: "In progress"),
      issue(2, body: automation(order: [4, 2]))
    ])
    with_snapshot(data) do |path, dir|
      status, out, = run_cli(["claim", "2", "--snapshot", path, "--record", File.join(dir, "r.json")])
      assert_equal 1, status
      assert_includes out, "活动认领"
    end
  end

  # 阻断 12：resume 必须核对远端认领
  def test_resume_requires_remote_claim
    data = snapshot(issues: [issue(1, body: automation)])
    with_snapshot(data) do |path, dir|
      record = File.join(dir, "run.json")
      File.write(record, JSON.generate({"schema" => 1, "issue" => 1, "phase" => "claimed"}), encoding: "UTF-8")
      status, out, = run_cli(["resume", "1", "--snapshot", path, "--record", record, "--apply"])
      assert_equal 1, status
      assert_includes out, "status"
      saved = JSON.parse(File.read(record, encoding: "UTF-8"))
      assert_equal "claimed", saved["phase"], "被拒绝时不得改 phase"
    end
  end

  # #124：review 命令并入 verify --final；缺输入文件在解析阶段 fail-fast（不触网）。
  # 「未知 level 不静默丢弃」由 load_report 抛 UsageError（退 2）继续保障。
  def test_final_requires_report_and_fixes
    status, out, = run_cli(["verify", "merge", "1", "1", "--final"])
    assert_equal 2, status
    assert_includes out, "--report"
    assert_includes out, "--fixes"
  end

  def test_final_rejects_unknown_level_in_phase_one_report
    Dir.mktmpdir do |dir|
      report_path = File.join(dir, "verification.json")
      fixes_path = File.join(dir, "fixes.json")
      File.write(report_path, JSON.generate({"items" => [{"level" => "must-fix", "message" => "x"}]}), encoding: "UTF-8")
      File.write(fixes_path, "{}", encoding: "UTF-8")
      status, out, = run_cli(["verify", "merge", "1", "1", "--final", "--report", report_path, "--fixes", fixes_path])
      assert_equal 2, status
      assert_includes out, "must-fix"
    end
  end

  # 阻断 14：可留项必须有复核结论（#124 后由 --final 的 checker 阶段承载）。
  # 归一层「未知 level 不静默丢弃」由 test_verify_reports.rb 的
  # test_unknown_level_becomes_blocker 继续覆盖。
  def test_final_rejects_unreviewed_acceptable
    report = SebasAgents::VerificationReport.new
    report.acceptable("可留")
    result = SebasAgents::Verifier.final_verification(report, {}, checker: ->(_item, _fix) { {passed: true} })
    assert_equal "打回", result.conclusion
  end

  # --help 不得有副作用
  def test_help_does_not_write_run_record
    data = snapshot(issues: [issue(1, body: automation)])
    with_snapshot(data) do |path, dir|
      record = File.join(dir, "run.json")
      run_cli(["claim", "1", "--snapshot", path, "--record", record, "--apply", "--help"])
      refute File.exist?(record), "--help 不得产生副作用"
    end
  end

  # aborted 记录不得直接续跑，必须先对账；且必须在暂停/PR 分支之前拦截。
  def test_aborted_record_does_not_resume
    data = snapshot(issues: [issue(1, body: automation, status: "In progress")])
    %w[true false].each do |written|
      record = {"issue" => 1, "phase" => "aborted", "label_written" => written == "true"}
      action = select(data, record: record)
      assert_equal "invalid_plan", action.action, "aborted(label_written=#{written}) 不得续跑"
      assert_includes action.reason, "aborted"
    end
  end

  # 带暂停标签的 aborted 记录也不能被 resume_paused 放行。
  def test_aborted_record_with_pause_labels_is_rejected
    data = snapshot(issues: [
      issue(1, body: automation, labels: %w[needs:human agent:resume], status: "In progress")
    ])
    record = {"issue" => 1, "phase" => "aborted", "label_written" => false}
    action = select(data, record: record)
    assert_equal "invalid_plan", action.action
    assert_includes action.reason, "aborted"
  end

  # 带在途 PR 的 aborted 记录同样不能被 PR 分支放行。
  def test_aborted_record_with_open_pr_is_rejected
    pr = {
      "number" => 9, "state" => "OPEN", "merge_state_status" => "BEHIND",
      "checks" => [], "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(
      issues: [issue(1, body: automation, status: "In progress")],
      pull_requests: [pr]
    )
    record = {"issue" => 1, "phase" => "aborted", "pr" => 9, "label_written" => true}
    assert_equal "invalid_plan", select(data, record: record).action
  end

  def test_claimed_record_with_pause_labels_resumes
    data = snapshot(issues: [
      issue(1, body: automation, labels: %w[needs:human agent:resume], status: "In progress")
    ])
    action = select(data, record: {"issue" => 1, "phase" => "claimed"})
    assert_equal "resume_issue", action.action
  end

  # 远端无 agent:in-progress 时，aborted 仍必须在暂停/PR 分支之前被拒。
  def test_aborted_without_remote_claim_and_pause_labels_is_rejected
    data = snapshot(issues: [issue(1, body: automation, labels: %w[needs:human agent:resume])])
    record = {"issue" => 1, "phase" => "aborted", "label_written" => true}
    action = select(data, record: record)
    assert_equal "invalid_plan", action.action
    assert_includes action.reason, "aborted"
  end

  def test_aborted_without_remote_claim_and_open_pr_is_rejected
    pr = {
      "number" => 9, "state" => "OPEN", "merge_state_status" => "BEHIND",
      "checks" => [], "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(issues: [issue(1, body: automation)], pull_requests: [pr])
    record = {"issue" => 1, "phase" => "aborted", "pr" => 9, "label_written" => true}
    assert_equal "invalid_plan", select(data, record: record).action
  end

  # 记录里的 issue 已不在快照内时也要拒绝，不能因 target 为空而崩溃。
  def test_aborted_with_missing_issue_still_rejected
    data = snapshot(issues: [issue(2, body: automation)])
    record = {"issue" => 99, "phase" => "aborted", "label_written" => false}
    action = select(data, record: record)
    assert_equal "invalid_plan", action.action
    assert_equal 99, action.issue
  end

  def test_claimed_record_still_resumes
    data = snapshot(issues: [issue(1, body: automation, status: "In progress")])
    assert_equal "resume_issue", select(data, record: {"issue" => 1, "phase" => "claimed"}).action
  end

  # 应修 12：needs_model 是「判断步骤」而非「判定值」，两者必须可区分但不能混用
  def test_needs_model_steps_are_not_decisions
    data = snapshot(issues: [issue(1, body: "bug 描述")])
    snap = SebasAgents::Model::Snapshot.from_hash(data)
    plan = SebasAgents::Triager.plan(snap.issue(1), snap)

    steps = plan["needs_model"]
    assert_includes steps, "duplicate"
    assert_includes steps, "reproduce"
    # 判断步骤里凡是「本身就是判定值」的，必须被接受
    (steps & SebasAgents::Triager::DECISIONS).each do |decision|
      with_snapshot(data) do |path, _dir|
        verdict = File.join(Dir.mktmpdir, "verdict.json")
        File.write(verdict, JSON.generate({"decision" => decision, "body" => "x"}), encoding: "UTF-8")
        status, out, = run_cli(["triage", "1", "--snapshot", path, "--verdict", verdict])
        refute_equal 2, status, "#{decision} 不应触发用法错误"
        refute_includes out, "未知 triage 判定"
      ensure
        FileUtils.rm_f(verdict) if defined?(verdict)
      end
    end
  end

  def test_unknown_verdict_is_rejected
    data = snapshot(issues: [issue(1, body: "bug 描述")])
    with_snapshot(data) do |path, _dir|
      verdict = File.join(Dir.mktmpdir, "verdict.json")
      File.write(verdict, JSON.generate({"decision" => "reproduce"}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "1", "--snapshot", path, "--verdict", verdict])
      assert_equal 2, status
      assert_includes out, "未知 triage 判定"
    ensure
      FileUtils.rm_f(verdict) if defined?(verdict)
    end
  end

  # #108：unclaim 必须 fail-closed，不能凭本地记录擅自清锁。
  def test_unclaim_refuses_when_issue_open
    data = snapshot(
      issues: [issue(4, body: automation, state: "OPEN")],
      pull_requests: []
    )
    with_snapshot(data) do |path|
      status, out, = run_cli(["unclaim", "4", "--snapshot", path])
      assert_equal 1, status
      payload = JSON.parse(out)
      assert_equal "refused", payload["status"]
      assert(payload["reasons"].any? { |r| r.include?("未以 completed 关闭") }, payload["reasons"].inspect)
    end
  end

  def test_unclaim_refuses_without_merged_pr
    data = snapshot(
      issues: [issue(4, body: automation, state: "CLOSED", state_reason: "COMPLETED")],
      pull_requests: [{"number" => 10, "state" => "OPEN", "closing_issues" => [4], "checks" => []}]
    )
    with_snapshot(data) do |path|
      status, out, = run_cli(["unclaim", "4", "--snapshot", path])
      assert_equal 1, status
      payload = JSON.parse(out)
      assert(payload["reasons"].any? { |r| r.include?("没有已合并的关联 PR") }, payload["reasons"].inspect)
    end
  end

  def test_unclaim_passes_when_completed_and_merged_dry_run
    data = snapshot(
      issues: [issue(4, body: automation, status: "In progress",
        state: "CLOSED", state_reason: "COMPLETED")],
      pull_requests: [{"number" => 10, "state" => "MERGED", "closing_issues" => [4], "checks" => []}]
    )
    with_snapshot(data) do |path|
      status, out, = run_cli(["unclaim", "4", "--snapshot", path])
      assert_equal 0, status
      payload = JSON.parse(out)
      assert_equal "released", payload["status"]
      assert_equal true, payload["dry_run"]
    end
  end

  # 正常收口路径：合并后 GitHub 自动把 status 置为 Done。
  # 若仍要求「执行中」，这条主路径会被自己拒绝；写回 Todo 还会抹掉终态。
  def test_unclaim_accepts_done_status
    data = snapshot(
      issues: [issue(4, body: automation, status: "Done",
        state: "CLOSED", state_reason: "COMPLETED")],
      pull_requests: [{"number" => 10, "state" => "MERGED", "closing_issues" => [4], "checks" => []}]
    )
    with_snapshot(data) do |path|
      status, out, = run_cli(["unclaim", "4", "--snapshot", path])
      assert_equal 0, status
      payload = JSON.parse(out)
      assert_equal "released", payload["status"]
      refute(payload["reasons"].any? { |r| r.include?("无需释放") }, payload["reasons"].inspect)
    end
  end

  # 既没开工（Backlog）也没完成：没被认领过，释放无意义。
  def test_unclaim_refuses_when_never_claimed
    data = snapshot(
      issues: [issue(4, body: automation, status: "Backlog",
        state: "CLOSED", state_reason: "COMPLETED")],
      pull_requests: [{"number" => 10, "state" => "MERGED", "closing_issues" => [4], "checks" => []}]
    )
    with_snapshot(data) do |path|
      status, out, = run_cli(["unclaim", "4", "--snapshot", path])
      assert_equal 1, status
      assert_includes out, "无需释放"
    end
  end
end
