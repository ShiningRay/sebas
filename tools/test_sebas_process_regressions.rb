# frozen_string_literal: true

# 对应 2026-11-21 只读复核列出的缺陷，逐条固化为回归用例。
# 每条都曾在真实命令上复现过，不是推测。
require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "agents/lib/sebas_agents"
require_relative "test_sebas_process"

class CliRobustnessTest < Minitest::Test
  include SnapshotHelpers

  def test_proposal_snapshot_resolves_registered_verdict_author_and_body
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    issue = SebasAgents::Model::Issue.from_hash({
      "number" => 8, "labels" => ["proposal"],
      "body" => "<!-- proposal-decision: #{url} -->"
    })
    runner = Object.new
    runner.define_singleton_method(:json!) do |*_args|
      {"user" => {"login" => "ShiningRay"}, "body" => "<!-- proposal-verdict: accepted-design -->"}
    end
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    refs = gateway.send(:proposal_decision_refs, issue.body)
    authors = gateway.send(:resolve_authors, refs)
    bodies = gateway.send(:resolve_bodies, refs)
    data = snapshot(issues: []).merge("source_authors" => authors, "source_bodies" => bodies)
    snap = SebasAgents::Model::Snapshot.from_hash(data)
    plan = SebasAgents::Triager.plan(issue, snap, verdict: {"decision" => "accepted-design", "maintainer_decision_url" => url})
    assert plan["ok"]
    assert_equal "ShiningRay", authors[url]
    assert_includes plan["comment"], url
  end

  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = SebasAgents::CLI.new(out: out, err: err).run(argv)
    [status, out.string, err.string]
  end

  def with_snapshot(data)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      yield path, dir
    end
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
      issue(1, body: automation, labels: ["agent:in-progress"]),
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
      assert_includes out, "agent:in-progress"
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
    data = snapshot(issues: [issue(1, body: automation, labels: ["agent:in-progress"])])
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
      issue(1, body: automation, labels: %w[agent:in-progress needs:human agent:resume])
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
      issues: [issue(1, body: automation, labels: ["agent:in-progress"])],
      pull_requests: [pr]
    )
    record = {"issue" => 1, "phase" => "aborted", "pr" => 9, "label_written" => true}
    assert_equal "invalid_plan", select(data, record: record).action
  end

  def test_claimed_record_with_pause_labels_resumes
    data = snapshot(issues: [
      issue(1, body: automation, labels: %w[agent:in-progress needs:human agent:resume])
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
    data = snapshot(issues: [issue(1, body: automation, labels: ["agent:in-progress"])])
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
      issues: [issue(4, body: automation, labels: ["agent:in-progress"],
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
end

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
      issues: [issue(1, body: automation, labels: %w[needs:human agent:in-progress])],
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

class GatewayRegressionTest < Minitest::Test
  # 阻断 6：GraphQL 出错不得当成无 thread
  def test_graphql_error_is_not_empty_threads
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    runner.define_singleton_method(:json!) { |*_args| {"errors" => [{"message" => "boom"}]} }
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_review_threads, 5) }
    assert_includes error.message, "reviewThreads"
  end

  def test_graphql_null_data_is_not_empty_threads
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    runner.define_singleton_method(:json!) { |*_args| {"data" => {"repository" => nil}} }
    assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_review_threads, 5) }
  end

  # 阻断 7：分页返回错误体不得变成空列表
  def test_pagination_error_body_raises
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    runner.define_singleton_method(:json!) { |*_args| {"message" => "Bad credentials"} }
    assert_raises(SebasAgents::CommandError) { gateway.send(:paginate, "repos/o/r/issues") }
  end

  # 应修 1：StatusContext PENDING 不得判绿
  def test_pending_status_context_is_not_green
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    checks = gateway.send(:normalize_checks, [{"context" => "ci", "state" => "PENDING"}])
    pr = SebasAgents::Model::PullRequest.from_hash("number" => 1, "checks" => checks)
    refute pr.checks_green?
  end
end

class VerifierRegressionTest < Minitest::Test
  include SnapshotHelpers

  # 阻断 15：锚点越界
  def test_anchor_line_out_of_range_is_blocker
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "x.cr"), "line1\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_code_anchors(
        [{"file" => "src/x.cr", "line" => 999, "content" => "line1"}], root: dir
      )
      refute report.pass?
      assert_equal 1, report.blockers.length
    end
  end

  def test_anchor_line_zero_is_blocker
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "x.cr"), "line1\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_code_anchors(
        [{"file" => "src/x.cr", "line" => 0, "content" => "line1"}], root: dir
      )
      refute report.pass?
    end
  end

  def test_anchor_without_content_is_blocker
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "x.cr"), "line1\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_code_anchors(
        [{"file" => "src/x.cr", "line" => 1}], root: dir
      )
      refute report.pass?
    end
  end

  # 应修 2：失败检查必须阻断
  def test_verify_merge_blocks_on_failing_checks
    data = snapshot(
      issues: [issue(39, body: automation, state: "CLOSED", state_reason: "COMPLETED")],
      pull_requests: [{
        "number" => 10, "state" => "MERGED", "closing_issues" => [39],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "FAILURE"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data))
    refute report.pass?
  end

  # #107：合并前模式不能因为「未合并 / 未关闭」而必然失败。
  # 但仍须满足可提前判定的条件：Evidence accepted + thread 清空 + CI 全绿。
  def test_verify_merge_pre_passes_when_ci_green
    body = automation + evidence(subject: "issue:39", merged: false)
    data = snapshot(
      issues: [issue(39, body: body, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39], "review_threads" => [],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    assert report.pass?, report.items.map(&:message).inspect
  end

  def test_verify_merge_post_blocks_when_not_merged
    data = snapshot(
      issues: [issue(39, body: automation, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data))
    refute report.pass?
    assert(report.blockers.any? { |b| b.message.include?("未合并") })
  end

  def test_verify_merge_pre_still_blocks_on_failing_ci
    data = snapshot(
      issues: [issue(39, body: automation, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "FAILURE"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?
  end

  def test_verify_merge_pre_blocks_when_issue_already_closed
    data = snapshot(
      issues: [issue(39, body: automation, state: "CLOSED", state_reason: "COMPLETED")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?
    assert(report.blockers.any? { |b| b.message.include?("已关闭") }, report.items.map(&:message).inspect)
  end

  # #107 核心：合并前自检必须覆盖 Evidence 与 review thread。
  def test_verify_merge_pre_blocks_without_evidence
    data = snapshot(
      issues: [issue(39, body: automation, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39], "review_threads" => [],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?
    assert(report.blockers.any? { |b| b.message.include?("缺 Evidence") }, report.items.map(&:message).inspect)
  end

  def test_verify_merge_pre_blocks_with_unresolved_threads
    body = automation + evidence(subject: "issue:39", merged: false)
    data = snapshot(
      issues: [issue(39, body: body, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39],
        "review_threads" => [{"id" => "t1", "is_resolved" => false}],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?
    assert(report.blockers.any? { |b| b.message.include?("未解决 review thread") }, report.items.map(&:message).inspect)
  end

  def test_verify_merge_pre_blocks_on_untested_items
    body = automation + evidence(subject: "issue:39", untested: ["真机 round-trip"])
    data = snapshot(
      issues: [issue(39, body: body, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39], "review_threads" => [],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?
    assert(report.blockers.any? { |b| b.message.include?("未实测") }, report.items.map(&:message).inspect)
  end

  def test_verify_merge_pre_passes_with_evidence_and_clean_threads
    body = automation + evidence(subject: "issue:39", merged: false)
    data = snapshot(
      issues: [issue(39, body: body, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39], "review_threads" => [],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    assert report.pass?, report.items.map(&:message).inspect
  end

  # CR：checks 为空说明快照没取到 CI 结果，不能当成「没有失败 = 全绿」放行。
  def test_verify_merge_pre_blocks_when_no_checks_recorded
    body = automation + evidence(subject: "issue:39", merged: false)
    data = snapshot(
      issues: [issue(39, body: body, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39], "review_threads" => [],
        "checks" => []
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?, "空 checks 必须阻断"
    assert(report.blockers.any? { |b| b.message.include?("没有任何 CI 检查记录") },
      report.items.map(&:message).inspect)
  end

  # CR 安全项：--pre 不能只看 status 字段，必须走 trusted? 授权校验。
  def test_verify_merge_pre_blocks_on_untrusted_evidence_source
    body = automation + evidence(subject: "issue:39", merged: false)
    data = snapshot(
      issues: [issue(39, body: body, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39], "review_threads" => [],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "random-user"}
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?
    assert(report.blockers.any? { |b| b.message.include?("未由 Maintainer 或受信 bot 登记") },
      report.items.map(&:message).inspect)
  end
end
