# frozen_string_literal: true

# 合并队列自动触发（M4x-Parallel-WP4，#222；Proposal §8 阶段 4）。
#
# 覆盖四块：
# - `auto_merge_enabled` 配置键（缺省 false / 布尔校验 fail-closed）
# - verifier 摘要评论解析（区分「通过」与「有条件通过」的唯一机械依据）
# - AutoMerge.gate 纯函数（终验门、失败预算）
# - `queue --auto` CLI（关停、dry-run 报告、verify_pre 接续、预算与重置）

require "fileutils"
require "socket"

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

# 带锁路由与可配置评论响应的替身 runner：继承 CommandRunner（dry_run? 契约），
# ref 锁走 RefLockStub，PR 评论分页返回预置数组；其余远端调用一律 CommandError
# （fail-closed，防止测试悄悄放行未预期的 gh 调用）。
class AutoFakeRunner < SebasAgents::CommandRunner
  include RefLockStub

  COMMENTS_PATH = %r{\Arepos/o/r/issues/\d+/comments\?}

  attr_reader :argvs

  def initialize(comments: [])
    super(dry_run: false)
    @comments = comments
    @argvs = []
  end

  def run!(*argv, chdir: Dir.pwd)
    @argvs << argv
    if (write = ref_lock_write(argv))
      return write
    end
    ""
  end

  def json!(*argv, chdir: Dir.pwd)
    @argvs << argv
    if (read = ref_lock_read(argv))
      return read
    end
    path = argv[2].to_s
    return @comments if path.match?(COMMENTS_PATH)

    raise SebasAgents::CommandError.new("stub: 未桩化的远端调用 #{path}", command: argv)
  end
end

class AutoMergeConfigTest < Minitest::Test
  def write_config(dir, content)
    gh_dir = File.join(dir, ".github")
    Dir.mkdir(gh_dir) unless Dir.exist?(gh_dir)
    File.write(File.join(gh_dir, "agents.yml"), content, encoding: "UTF-8")
  end

  def read_switch(dir)
    gateway = SebasAgents::GithubGateway.new(nil, repo: "o/r")
    Dir.chdir(dir) { gateway.auto_merge_enabled? }
  end

  def test_defaults_to_false_without_key
    Dir.mktmpdir do |dir|
      write_config(dir, "maintainers:\n  - ShiningRay\n")
      assert_equal false, read_switch(dir)
    end
  end

  def test_missing_file_defaults_to_false
    Dir.mktmpdir do |dir|
      assert_equal false, read_switch(dir)
    end
  end

  def test_reads_explicit_values
    Dir.mktmpdir do |dir|
      write_config(dir, "maintainers:\n  - ShiningRay\nauto_merge_enabled: true\n")
      assert_equal true, read_switch(dir)
    end
    Dir.mktmpdir do |dir|
      write_config(dir, "maintainers:\n  - ShiningRay\nauto_merge_enabled: false\n")
      assert_equal false, read_switch(dir)
    end
  end

  # 字符串 "true" 必须拒绝：静默转真值等于「以为关了其实开着」。
  def test_rejects_non_boolean
    ["\"true\"", "1", "null"].each do |raw|
      Dir.mktmpdir do |dir|
        write_config(dir, "maintainers:\n  - ShiningRay\nauto_merge_enabled: #{raw}\n")
        assert_raises(SebasAgents::CommandError) { read_switch(dir) }
      end
    end
  end
end

class VerifierSummaryParseTest < Minitest::Test
  SUMMARY = SebasAgents::MergeQueue::VERIFIER_SUMMARY_MARKER

  def summary_body(unverified: 0, blocker: 0, must_fix: 0, acceptable: 2)
    <<~MD
      #{SUMMARY}
      ## Verifier 核验（证据收集）

      | 级别 | 数量 |
      |---|---|
      | blocker | #{blocker} |
      | must_fix | #{must_fix} |
      | acceptable | #{acceptable} |
      | unverified | #{unverified} |
    MD
  end

  def test_parses_counts_from_summary_comment
    counts = SebasAgents::MergeQueue.verifier_summary_from_body(summary_body(unverified: 1))
    assert_equal({"blocker" => 0, "must_fix" => 0, "acceptable" => 2, "unverified" => 1}, counts)
  end

  def test_body_without_marker_returns_nil
    assert_nil SebasAgents::MergeQueue.verifier_summary_from_body("普通评论")
    assert_nil SebasAgents::MergeQueue.verifier_summary_from_body(nil)
  end

  # 有 marker 但计数表残缺：结构坏了不能猜成 0 放行。
  def test_missing_count_row_raises
    body = summary_body.sub(/\|\s*unverified\s*\|\s*\d+\s*\|\n/, "")
    assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::MergeQueue.verifier_summary_from_body(body)
    end
  end
end

class AutoMergeGateTest < Minitest::Test
  def gate(step, summary:, failures: 0)
    SebasAgents::AutoMerge.gate(step: step, summary: summary, failures: failures)
  end

  def clean_summary
    {"blocker" => 0, "must_fix" => 0, "acceptable" => 2, "unverified" => 0}
  end

  def conditional_summary
    clean_summary.merge("unverified" => 1)
  end

  def test_budget_exceeded_blocks_any_step
    allowed, reason = gate("verify_pre", summary: nil, failures: 2)
    refute allowed
    assert_includes reason, "超出回退预算"
  end

  def test_single_failure_still_allows_one_retry
    allowed, = gate("verify_pre", summary: nil, failures: 1)
    assert allowed
  end

  def test_conditional_pass_blocks_merge
    allowed, reason = gate("merge", summary: conditional_summary, failures: 0)
    refute allowed
    assert_includes reason, "有条件通过"
    assert_includes reason, "交回 Maintainer"
  end

  def test_missing_summary_blocks_merge
    allowed, reason = gate("merge", summary: nil, failures: 0)
    refute allowed
    assert_includes reason, "缺 verifier 摘要评论"
  end

  def test_clean_summary_allows_merge
    allowed, = gate("merge", summary: clean_summary, failures: 0)
    assert allowed
  end

  def test_non_merge_step_needs_no_summary
    allowed, = gate("verify_pre", summary: nil, failures: 0)
    assert allowed
    allowed, = gate("update_branch", summary: nil, failures: 0)
    assert allowed
  end

  def test_only_verify_pre_chains_within_one_invocation
    assert SebasAgents::AutoMerge.continue_after?("verify_pre")
    refute SebasAgents::AutoMerge.continue_after?("merge")
    refute SebasAgents::AutoMerge.continue_after?("update_branch")
    refute SebasAgents::AutoMerge.continue_after?("changelog")
  end
end

class QueueAutoCommandTest < Minitest::Test
  include SnapshotHelpers
  include CliHelpers

  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = SebasAgents::CLI.new(out: out, err: err).run(argv)
    [status, out.string, err.string]
  end

  def write_config(dir, switch:)
    gh_dir = File.join(dir, ".github")
    FileUtils.mkdir_p(gh_dir)
    File.write(File.join(gh_dir, "agents.yml"),
      "maintainers:\n  - ShiningRay\ncoordinators:\n  - ShiningRay\n" \
      "trusted_bots:\n  - github-actions[bot]\ncapacity: 2\n" \
      "auto_merge_enabled: #{switch}\n", encoding: "UTF-8")
  end

  # verify merge --pre 可通过的夹具：CI 有记录且全绿、变更带 patch、
  # src/ 配齐 spec/ 与 docs/、scope 覆盖全部变更目录、Evidence accepted。
  def verified_pr_fixture(dir, issue: 1, pr_number: 50)
    pr_data = {
      "number" => pr_number, "head_ref_name" => "feat/#{issue}", "base_ref_name" => "main",
      "head_sha" => "sha#{pr_number}", "state" => "OPEN", "merged" => false,
      "merge_state_status" => "CLEAN",
      "checks" => [{"name" => "spec / ubuntu-latest", "status" => "COMPLETED", "conclusion" => "SUCCESS"}],
      "closing_issues" => [issue], "review_threads" => [], "body" => nil,
      "files" => [
        {"filename" => "src/x.cr", "patch" => "@@ -1 +1 @@"},
        {"filename" => "spec/x_spec.cr", "patch" => "@@ -1 +1 @@"},
        {"filename" => "docs/x.md", "patch" => "@@ -1 +1 @@"}
      ]
    }
    scope = ["src/", "spec/", "docs/"]
    data = snapshot(
      issues: [issue(issue, body: automation(scope: scope) + evidence(subject: "issue:#{issue}", merged: false),
        status: "In progress")],
      pull_requests: [pr_data],
      capacity: 2
    )
    path = File.join(dir, "s.json")
    File.write(path, JSON.generate(data), encoding: "UTF-8")

    runs = File.join(dir, ".sebas-agent", "runs")
    FileUtils.mkdir_p(runs)
    record_path = File.join(runs, "#{issue}.json")
    File.write(record_path, JSON.generate({
      "schema" => 2, "issue" => issue, "branch" => "feat/#{issue}", "phase" => "claimed",
      "pr" => pr_number, "host" => Socket.gethostname, "pid" => 999_999,
      "last_heartbeat_at" => "2020-01-01T00:00:00Z"
    }), encoding: "UTF-8")

    changelog = File.join(dir, "CHANGELOG.md")
    File.write(changelog, "## [Unreleased]\n", encoding: "UTF-8")
    [path, changelog, record_path]
  end

  def run_auto(dir, snap_path, changelog, apply:, runner: nil)
    argv = ["queue", "--auto", "--snapshot", snap_path, "--changelog", changelog]
    argv << "--apply" if apply
    out = StringIO.new
    cli = SebasAgents::CLI.new(out: out, err: StringIO.new)
    cli.define_singleton_method(:runner) { |_options| runner } if runner
    status = Dir.chdir(dir) { cli.run(argv) }
    [status, JSON.parse(out.string)]
  end

  def summary_comment(unverified:, login: "github-actions[bot]", head: "sha50")
    [{"body" => "<!-- verify-pr:summary -->\n\n核验脚本取自 base `deadbeef`，被核验内容取自 head `#{head}`。\n\n" \
                "| 级别 | 数量 |\n|---|---|\n" \
                "| blocker | 0 |\n| must_fix | 0 |\n| acceptable | 2 |\n| unverified | #{unverified} |\n",
      "user" => {"login" => login}}]
  end

  def seed_failures(record_path, count, step: "verify_pre")
    data = JSON.parse(File.read(record_path))
    File.write(record_path, JSON.generate(data.merge(
      "auto_merge_failures" => count, "auto_failed_step" => count.positive? ? step : nil
    )), encoding: "UTF-8")
  end

  def read_failures(record_path)
    JSON.parse(File.read(record_path))["auto_merge_failures"]
  end

  # 执行必败夹具：PR 仍 merge_ready（CI 绿、CLEAN），但正文声明了空 CHANGELOG
  # 围栏——changelog 步执行时 refused（「声明了待追加条目但解析为空」）。
  # 失败检查的 PR 进不了 merge_ready，测不了「执行失败」。
  def unparseable_changelog_fixture(dir, issue: 1, pr_number: 50)
    snap, changelog, record_path = verified_pr_fixture(dir, issue: issue, pr_number: pr_number)
    data = JSON.parse(File.read(snap))
    data["pull_requests"][0]["body"] = "<!-- sebas-changelog -->\n```text\n```\n"
    File.write(snap, JSON.generate(data), encoding: "UTF-8")
    [snap, changelog, record_path]
  end

  def test_disabled_switch_refuses_apply_and_reports_dry_run
    Dir.mktmpdir do |dir|
      write_config(dir, switch: false)
      snap, changelog, = verified_pr_fixture(dir)
      status, payload = run_auto(dir, snap, changelog, apply: true)
      assert_equal 1, status
      assert_equal "disabled", payload["status"]
      refute payload["ok"]
      assert_includes payload["reasons"].first, "auto_merge_enabled 未开启"

      status, payload = run_auto(dir, snap, changelog, apply: false)
      assert_equal 0, status
      assert_equal "disabled", payload["status"]
      assert payload["ok"], "dry-run 只报告，不判败"
    end
  end

  def test_dry_run_reports_first_step_without_executing
    Dir.mktmpdir do |dir|
      write_config(dir, switch: true)
      snap, changelog, record_path = verified_pr_fixture(dir)
      status, payload = run_auto(dir, snap, changelog, apply: false, runner: AutoFakeRunner.new)
      assert_equal 0, status
      assert_equal "would_execute", payload["status"]
      assert_equal "verify_pre", payload["step"]
      assert_includes payload["reasons"].first, "接续"
      # dry-run 不得写运行记录（verified_head 仍未写）
      refute JSON.parse(File.read(record_path)).key?("verified_head")
    end
  end

  def test_budget_exceeded_blocks_without_fetching_summary
    Dir.mktmpdir do |dir|
      write_config(dir, switch: true)
      snap, changelog, record_path = verified_pr_fixture(dir)
      seed_failures(record_path, 2)
      # 记录里已核验到 head：队列直接给出 merge 步；预算超限时连评论分页
      # 都不该发生——runner 对评论路径一无所知，被调用即报错。
      data = JSON.parse(File.read(record_path))
      File.write(record_path, JSON.generate(data.merge("verified_head" => "sha50")), encoding: "UTF-8")
      status, payload = run_auto(dir, snap, changelog, apply: false, runner: AutoFakeRunner.new)
      assert_equal 0, status
      assert_equal "blocked", payload["status"]
      assert_includes payload["auto_gate"], "超出回退预算"
    end
  end

  # 链路：verify_pre 成功（写核验记录）→ 同一轮接续 merge → 摘要缺失被门挡下。
  # 门拒判是「交人工」的正常停轮，不计入回退预算——预算只数执行失败。
  def test_apply_chains_verify_pre_then_blocks_on_missing_summary
    Dir.mktmpdir do |dir|
      write_config(dir, switch: true)
      snap, changelog, record_path = verified_pr_fixture(dir)
      status, payload = run_auto(dir, snap, changelog, apply: true, runner: AutoFakeRunner.new(comments: []))
      assert_equal 1, status
      assert_equal "blocked", payload["status"]
      assert_includes payload["auto_gate"], "缺 verifier 摘要评论"
      assert_equal "verified", payload["auto_steps"].first["result"]
      # verify_pre 的核验记录已写（否则队列到不了 merge 步）
      assert_equal "sha50", JSON.parse(File.read(record_path))["verified_head"]
      refute JSON.parse(File.read(record_path)).key?("auto_merge_failures"),
        "门拒判（缺摘要）是交人工，不是执行失败，不得计入回退预算"
    end
  end

  # 执行失败才计入预算：第一轮 verify_pre 成功后接续 changelog 步，该步执行
  # refused（空围栏）→ +1；重试一次再败 → 2；第三轮预算耗尽，gate 直接拒且
  # 不再累计。
  def test_execution_failures_exhaust_budget
    Dir.mktmpdir do |dir|
      write_config(dir, switch: true)
      snap, changelog, record_path = unparseable_changelog_fixture(dir)
      status, payload = run_auto(dir, snap, changelog, apply: true, runner: AutoFakeRunner.new)
      assert_equal 1, status
      assert_equal "aborted", payload["status"]
      assert_equal "verified", payload["auto_steps"].first["result"]
      assert_equal 1, read_failures(record_path), "执行失败必须计入回退预算"

      status, = run_auto(dir, snap, changelog, apply: true, runner: AutoFakeRunner.new)
      assert_equal 1, status
      assert_equal 2, read_failures(record_path)

      status, payload = run_auto(dir, snap, changelog, apply: true, runner: AutoFakeRunner.new)
      assert_equal 1, status
      assert_includes payload["auto_gate"], "超出回退预算"
      assert_equal 2, read_failures(record_path), "预算耗尽后不得继续累计"
    end
  end

  def test_conditional_pass_blocks_merge_in_apply
    Dir.mktmpdir do |dir|
      write_config(dir, switch: true)
      snap, changelog, record_path = verified_pr_fixture(dir)
      data = JSON.parse(File.read(record_path))
      File.write(record_path, JSON.generate(data.merge("verified_head" => "sha50")), encoding: "UTF-8")
      status, payload = run_auto(dir, snap, changelog, apply: true,
        runner: AutoFakeRunner.new(comments: summary_comment(unverified: 1)))
      assert_equal 1, status
      assert_equal "blocked", payload["status"]
      assert_includes payload["auto_gate"], "有条件通过"
      refute JSON.parse(File.read(record_path)).key?("auto_merge_failures"),
        "有条件通过是交 Maintainer 的人工通道，不计入回退预算"
    end
  end

  # 摘要干净（unverified=0）时 gate 放行 merge：执行进入 queue_apply_step! 的
  # merge 段，其后对远端的全量快照复核在桩上必然失败（fail-closed）——
  # 断言点是「链走到了 merge」：verify_pre 成功入 auto_steps，异常来自写段。
  def test_clean_summary_proceeds_into_merge_step
    Dir.mktmpdir do |dir|
      write_config(dir, switch: true)
      snap, changelog, record_path = verified_pr_fixture(dir)
      status, payload = run_auto(dir, snap, changelog, apply: true,
        runner: AutoFakeRunner.new(comments: summary_comment(unverified: 0)))
      assert_equal 1, status
      assert_equal "verified", payload["auto_steps"].first["result"]
      assert_equal "verify_pre", payload["auto_steps"].first["step"]
      assert_includes payload["reasons"].first, "合并队列写段异常"
      assert_equal 1, read_failures(record_path), "merge 段的执行失败计入回退预算"
    end
  end

  def test_manual_apply_success_resets_budget
    Dir.mktmpdir do |dir|
      write_config(dir, switch: true)
      snap, changelog, record_path = verified_pr_fixture(dir)
      seed_failures(record_path, 2)
      # 人工通道（不带 --auto）：走 verify_pre 成功一步 → 计数清零
      out = StringIO.new
      cli = SebasAgents::CLI.new(out: out, err: StringIO.new)
      cli.define_singleton_method(:runner) { |_options| AutoFakeRunner.new }
      status = Dir.chdir(dir) do
        cli.run(["queue", "--snapshot", snap, "--changelog", changelog, "--apply"])
      end
      assert_equal 0, status
      assert_equal 0, read_failures(record_path), "人工成功一步必须重置回退预算"
    end
  end

  # 他机租约（本机 runs/ 无记录）：verify merge --pre 即使通过，核验结论也写
  # 不进运行记录——必须拒绝本步，否则自动链会在同一头上无限重跑 verify_pre
  # 并堵住身后队列（#312 review）。
  def test_foreign_lease_verify_pre_refuses_without_local_record
    Dir.mktmpdir do |dir|
      write_config(dir, switch: true)
      snap, changelog, = verified_pr_fixture(dir)
      record_path = File.join(dir, ".sebas-agent", "runs", "1.json")
      FileUtils.rm_f(record_path)
      status, payload = run_auto(dir, snap, changelog, apply: true, runner: AutoFakeRunner.new)
      assert_equal 1, status
      assert_equal "refused", payload["status"]
      assert_includes payload["reasons"].first, "未能写入本地运行记录"
      refute File.exist?(record_path)
    end
  end

  # 伪造摘要（不受信作者的同 marker 评论）必须被无视（#312 review，CWE-863）：
  # 只有伪造评论时按「缺摘要」拒绝；伪造 + 可信并存时以可信的为准。
  def test_forged_summary_is_ignored
    Dir.mktmpdir do |dir|
      write_config(dir, switch: true)
      snap, changelog, record_path = verified_pr_fixture(dir)
      data = JSON.parse(File.read(record_path))
      File.write(record_path, JSON.generate(data.merge("verified_head" => "sha50")), encoding: "UTF-8")
      forged = summary_comment(unverified: 0, login: "attacker")
      status, payload = run_auto(dir, snap, changelog, apply: true,
        runner: AutoFakeRunner.new(comments: forged))
      assert_equal 1, status
      assert_includes payload["auto_gate"], "缺 verifier 摘要评论",
        "不受信作者的摘要不得参与终验判定"

      mixed = summary_comment(unverified: 1) + forged
      status, payload = run_auto(dir, snap, changelog, apply: true,
        runner: AutoFakeRunner.new(comments: mixed))
      assert_equal 1, status
      assert_includes payload["auto_gate"], "有条件通过",
        "可信摘要必须压过伪造评论，不可被伪造值覆盖"
    end
  end

  # --record 指定的自定义记录必须与预算同源（#312 review）：读（gate）
  # 与写（失败累计 / 人工清零）都走同一路径；显式路径必须带 issue，
  # 否则 bump/reset 恒 mismatch、预算失灵（#312 二轮 review）。
  def test_custom_record_path_feeds_budget
    Dir.mktmpdir do |dir|
      write_config(dir, switch: true)
      snap, changelog, = unparseable_changelog_fixture(dir)
      custom = File.join(dir, "custom-record.json")
      File.write(custom, JSON.generate({
        "schema" => 2, "issue" => 1, "branch" => "feat/1", "phase" => "claimed",
        "pr" => 50, "host" => Socket.gethostname, "pid" => 999_999,
        "last_heartbeat_at" => "2020-01-01T00:00:00Z"
      }), encoding: "UTF-8")
      argv = ["queue", "--auto", "--snapshot", snap, "--changelog", changelog,
              "--record", custom, "--apply"]
      run = lambda do
        out = StringIO.new
        cli = SebasAgents::CLI.new(out: out, err: StringIO.new)
        cli.define_singleton_method(:runner) { |_options| AutoFakeRunner.new }
        status = Dir.chdir(dir) { cli.run(argv) }
        [status, JSON.parse(out.string)]
      end

      # 空围栏 → verify_pre 写进自定义记录后接续 changelog，该步执行 refused
      # → 失败累计必须落进自定义文件（而不是 mismatch 静默丢掉）
      status, payload = run.call
      assert_equal 1, status
      assert_equal "aborted", payload["status"]
      counter = -> { JSON.parse(File.read(custom))["auto_merge_failures"] }
      assert_equal 1, counter.call, "自定义记录必须能累计执行失败"
      run.call
      assert_equal 2, counter.call

      # 第三轮：预算从自定义记录读出，gate 直接拒
      status, payload = run.call
      assert_equal 1, status
      assert_includes payload["auto_gate"], "超出回退预算"

      # 人工通道成功一步（无 changelog 声明的夹具）→ 清零也要写自定义记录。
      # 先清掉 verified_head 让队列回到 verify_pre（merge 步会撞远端桩）。
      custom_data = JSON.parse(File.read(custom))
      File.write(custom, JSON.generate(custom_data.merge("verified_head" => nil)), encoding: "UTF-8")
      snap_ok, changelog_ok, = verified_pr_fixture(dir)
      manual = ["queue", "--snapshot", snap_ok, "--changelog", changelog_ok,
                "--record", custom, "--apply"]
      out = StringIO.new
      cli = SebasAgents::CLI.new(out: out, err: StringIO.new)
      cli.define_singleton_method(:runner) { |_options| AutoFakeRunner.new }
      status = Dir.chdir(dir) { cli.run(manual) }
      assert_equal 0, status
      assert_equal 0, counter.call, "人工清零必须写回自定义记录"
    end
  end

  # 摘要与 head 绑定（#312 二轮 review）：发布步骤 continue-on-error 时旧
  # head 的摘要残留——不含当前 head 的可信摘要视同缺失，不得放行合并。
  def test_stale_head_summary_is_ignored
    Dir.mktmpdir do |dir|
      write_config(dir, switch: true)
      snap, changelog, record_path = verified_pr_fixture(dir)
      data = JSON.parse(File.read(record_path))
      File.write(record_path, JSON.generate(data.merge("verified_head" => "sha50")), encoding: "UTF-8")
      stale = summary_comment(unverified: 0, head: "oldsha")
      status, payload = run_auto(dir, snap, changelog, apply: true,
        runner: AutoFakeRunner.new(comments: stale))
      assert_equal 1, status
      assert_includes payload["auto_gate"], "缺 verifier 摘要评论",
        "旧 head 的摘要对新 head 不成立，必须按缺失拒绝"
    end
  end

  # 预算读改写必须走记录锁（#312 review）：锁被占时不得静默写丢。
  def test_bump_auto_failure_respects_record_lock
    Dir.mktmpdir do |dir|
      runs = File.join(dir, ".sebas-agent", "runs")
      FileUtils.mkdir_p(runs)
      record_path = File.join(runs, "1.json")
      File.write(record_path, JSON.generate({
        "schema" => 2, "issue" => 1, "branch" => "feat/1", "phase" => "claimed"
      }), encoding: "UTF-8")
      # RunRecord.new(issue:) 走相对路径，须在临时目录内使用
      Dir.chdir(dir) do
        record = SebasAgents::RunRecord.new(issue: 1)
        assert_equal :ok, record.bump_auto_failure!("verify_pre")
        assert_equal 1, JSON.parse(File.read(record_path))["auto_merge_failures"]

        # 占住同一把 #{path}.lock（pid 活跃 → 非残留）→ 计数不得写入且须可观测
        File.write("#{record_path}.lock", Process.pid.to_s, encoding: "UTF-8")
        assert_equal :locked, record.bump_auto_failure!("verify_pre")
        assert_equal "locked", record.mutate_refusal
        assert_equal 1, JSON.parse(File.read(record_path))["auto_merge_failures"],
          "锁被占时的本次失败不得落盘（可观测后由下轮重试累计）"

        FileUtils.rm_f("#{record_path}.lock")
        assert_equal :ok, record.bump_auto_failure!("verify_pre")
        assert_equal 2, JSON.parse(File.read(record_path))["auto_merge_failures"]
      end
    end
  end
end

class PlanMergeQueueFieldTest < Minitest::Test
  include SnapshotHelpers
  include CliHelpers

  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = SebasAgents::CLI.new(out: out, err: err).run(argv)
    [status, out.string, err.string]
  end

  # plan 输出的合并队列状态：队首 PR、队列长度、阻塞原因（#222 §3 可观察性）。
  def test_plan_outputs_merge_queue_status
    pr_data = {
      "number" => 50, "head_ref_name" => "feat/1", "base_ref_name" => "main",
      "head_sha" => "sha50", "state" => "OPEN", "merged" => false,
      "merge_state_status" => "CLEAN", "checks" => [],
      "closing_issues" => [1], "review_threads" => [], "body" => nil,
      "files" => [{"filename" => "src/x.cr"}]
    }
    scope = ["src/"]
    data = snapshot(
      issues: [issue(1, body: automation(scope: scope), status: "In progress")],
      pull_requests: [pr_data],
      capacity: 2
    )
    Dir.mktmpdir do |dir|
      path = File.join(dir, "s.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      changelog = File.join(dir, "CHANGELOG.md")
      File.write(changelog, "## [Unreleased]\n", encoding: "UTF-8")
      status, out, = run_cli(["plan", "--snapshot", path, "--changelog", changelog])
      assert_equal 0, status
      payload = JSON.parse(out)
      mq = payload["merge_queue"]
      refute_nil mq
      assert_equal 1, mq["head"]
      assert_equal 50, mq["head_pr"]
      assert_equal 1, mq["depth"]
      assert_equal "verify_pre", mq["step"]
      refute_nil mq["blocked_by"]
    end
  end

  def test_plan_merge_queue_empty_when_no_merge_ready_leases
    data = snapshot(issues: [], pull_requests: [])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "s.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["plan", "--snapshot", path])
      assert_equal 0, status
      mq = JSON.parse(out)["merge_queue"]
      assert_nil mq["head"]
      assert_equal 0, mq["depth"]
    end
  end
end
