# frozen_string_literal: true

# `queue` 子命令（M4x-Parallel-WP3，#221）：只读合并队列规划。
#
# 只验证 CLI 契约与退出码；链上判定本身在 test_merge_queue.rb。

require "fileutils"

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
end
