# frozen_string_literal: true

# `queue` 子命令（M4x-Parallel-WP3，#221）：只读合并队列规划。
#
# 只验证 CLI 契约与退出码；链上判定本身在 test_merge_queue.rb。

require "fileutils"
require "socket"

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class QueueCommandTest < Minitest::Test
  include SnapshotHelpers
  include CliHelpers

  MARKER = SebasAgents::MergeQueue::CHANGELOG_MARKER

  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = SebasAgents::CLI.new(out: out, err: err).run(argv)
    [status, out.string, err.string]
  end

  def automation_with_scope(scope)
    automation(scope: scope)
  end

  def pr(number:, issue:, body: nil)
    {
      "number" => number, "head_ref_name" => "feat/#{issue}", "base_ref_name" => "main",
      "head_sha" => "sha#{number}", "state" => "OPEN", "merged" => false,
      "merge_state_status" => "CLEAN", "checks" => [],
      "closing_issues" => [issue], "review_threads" => [], "body" => body,
      "files" => [{"filename" => "src/x.cr"}]
    }
  end

  def write_snapshot(dir, data)
    path = File.join(dir, "s.json")
    File.write(path, JSON.generate(data), encoding: "UTF-8")
    path
  end

  def test_empty_queue_reports_no_head
    data = snapshot(issues: [], pull_requests: [])
    Dir.mktmpdir do |dir|
      status, out, = run_cli(["queue", "--snapshot", write_snapshot(dir, data),
                              "--changelog", File.join(dir, "CHANGELOG.md")])
      assert_equal 0, status
      payload = JSON.parse(out)
      assert payload["ok"]
      assert_equal true, payload["dry_run"], "默认必须只读"
      assert_empty payload["queue"]["entries"]
      assert_nil payload["queue"]["head"]
      assert_equal false, payload["changelog_loaded"]
    end
  end

  def test_clean_pr_with_changelog_block_is_planned
    body = "正文\n#{MARKER}\n```\n- 条目 (#50)\n```\n"
    data = snapshot(
      issues: [issue(1, body: automation_with_scope(["src/"]), status: "In progress")],
      pull_requests: [pr(number: 50, issue: 1, body: body)],
      capacity: 2
    )
    Dir.mktmpdir do |dir|
      snap_path = write_snapshot(dir, data)
      changelog = File.join(dir, "CHANGELOG.md")
      File.write(changelog, "## [Unreleased]\n", encoding: "UTF-8")

      # queue 的路由需要本地记录才认为租约属于本机
      runs = File.join(dir, ".sebas-agent", "runs")
      FileUtils.mkdir_p(runs)
      # verified_head 必须与 PR 当前 head 一致：队列以「当前 head 已核验」作为
      # 进入 changelog / merge 的前置，缺它一律回 verify_pre。
      File.write(File.join(runs, "1.json"), JSON.generate({
        "schema" => 2, "issue" => 1, "branch" => "feat/1", "phase" => "claimed", "pr" => 50,
        "verified_head" => "sha50"
      }), encoding: "UTF-8")

      Dir.chdir(dir) do
        status, out, = run_cli(["queue", "--snapshot", snap_path, "--changelog", changelog])
        assert_equal 0, status
        payload = JSON.parse(out)
        assert_equal 1, payload["queue"]["head"]
        assert_equal "changelog", payload["queue"]["step"]
        assert_equal 1, payload["queue"]["entries"].first["changelog_pending"].length
      end
    end
  end

  def test_help_lists_queue
    status, out, = run_cli(["queue", "--help"])
    assert_equal 0, status
    assert_includes out, "queue"
    assert_includes out, "合并队列"
  end

  # --pid 必须为正整数：0 会被归一为 nil，写进去等于埋坑。
  def test_heartbeat_rejects_non_positive_pid
    Dir.mktmpdir do |dir|
      rec = File.join(dir, "7.json")
      File.write(rec, JSON.generate({"schema" => 2, "issue" => 7, "phase" => "claimed"}),
        encoding: "UTF-8")
      ["0", "-5"].each do |pid|
        status, out, = run_cli(["heartbeat", "7", "--record", rec, "--apply", "--pid", pid])
        assert_equal 2, status, "非正数 pid 应判用法错误"
        assert_includes out, "正整数"
      end
      # 记录未被污染
      refute JSON.parse(File.read(rec)).key?("pid")
    end
  end


  # `queue --apply` 走 verify_pre 时，必须真的跑核验并把 head 写进运行记录，
  # 否则队列永远停在 verify_pre（`next_step` 要求 verified_head 等于当前 head）。
  #
  # 这条测试断言的是「写入点存在且被调用」——上一版只直调 next_step 并手传
  # verified_head，删掉 cli.rb 里的 remember_verified_head 也照样通过。
  def test_queue_apply_verify_pre_records_verified_head
    Dir.mktmpdir do |dir|
      pr_data = pr(number: 50, issue: 1)
      # verify --pre 的几项硬要求，缺一即 fail-closed：
      # - 有 CI 检查记录（否则「没看见」不能当通过）
      # - 变更文件带 patch（否则路径联动不可判定）
      # - src/ 改动需配 spec/ 与 docs/ 变更，或 PR 正文声明「无行为变更」
      pr_data["checks"] = [{"name" => "spec / ubuntu-latest", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      pr_data["files"] = [
        {"filename" => "src/x.cr", "patch" => "@@ -1 +1 @@"},
        {"filename" => "spec/x_spec.cr", "patch" => "@@ -1 +1 @@"},
        {"filename" => "docs/x.md", "patch" => "@@ -1 +1 @@"}
      ]
      # scope 必须覆盖被测的每个变更目录，否则 F14 会先判越界（needs_human），
      # 走不到 verify_pre。
      scope = ["src/", "spec/", "docs/"]
      data = snapshot(
        issues: [issue(1, body: automation(scope: scope), status: "In progress")],
        pull_requests: [pr_data],
        capacity: 2
      )
      # Evidence 必须 accepted 才能过 verify --pre
      data["issues"][0]["body"] = automation(scope: scope) +
                                  evidence(subject: "issue:1", merged: false)

      runs = File.join(dir, ".sebas-agent", "runs")
      FileUtils.mkdir_p(runs)
      record_path = File.join(runs, "1.json")
      File.write(record_path, JSON.generate({
        "schema" => 2, "issue" => 1, "branch" => "feat/1", "phase" => "claimed",
        "pr" => 50, "host" => Socket.gethostname, "pid" => 999_999,
        "last_heartbeat_at" => "2020-01-01T00:00:00Z"
      }), encoding: "UTF-8")

      snap_path = write_snapshot(dir, data)
      changelog = File.join(dir, "CHANGELOG.md")
      File.write(changelog, "## [Unreleased]\n", encoding: "UTF-8")

      Dir.chdir(dir) do
        status, out, = run_cli(["queue", "--snapshot", snap_path, "--changelog", changelog, "--apply"])
        payload = JSON.parse(out)
        # 规划阶段给出 verify_pre（尚无核验记录）
        assert_equal "verify_pre", payload["queue"]["step"]
        # 执行阶段真的跑了核验并落了记录
        assert_equal "verified", payload["status"], payload["reasons"].inspect
        assert_equal 0, status

        # 写入点必须真的生效——删掉 remember_verified_head 这里会变成 nil
        saved = JSON.parse(File.read(record_path))
        assert_equal "sha50", saved["verified_head"],
          "queue --apply 走过 verify_pre 后必须把 head 写进运行记录"

        # 再规划一次：核验记录已就位，应能进入 merge
        _, out2, = run_cli(["queue", "--snapshot", snap_path, "--changelog", changelog])
        assert_equal "merge", JSON.parse(out2)["queue"]["step"],
          "核验记录写入后队列必须能推进到 merge"
      end
    end
  end


  # help 必须写明 --pid 是 --apply 的必填项：否则读者会以为不带 pid 也能写。
  def test_help_documents_heartbeat_pid_requirement
    status, out, = run_cli(["help"])
    assert_equal 0, status
    assert_includes out, "heartbeat <issue> [--pid"
    assert_includes out, "--apply 才写，且此时 --pid 必填"
    # 只读模式不要求 pid：说明必须写清，否则读者会以为连查询也要 pid
    assert_includes out, "只读模式不给 --pid 也能用"
    assert_includes out, "--ttl 只作判据提示，不写入记录"
  end

end
