# frozen_string_literal: true

# CLI next/claim/verify --final 的入口行为：快照读取、认领写入与失败落 aborted。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class CliClaimTest < Minitest::Test
  include SnapshotHelpers
  include CliHelpers

  # #124：终验读阶段一的 verification.json，不现场生成报告。
  def write_report(dir, items)
    path = File.join(dir, "verification.json")
    File.write(path, JSON.generate({"items" => items}), encoding: "UTF-8")
    path
  end

  def write_fixes(dir, data)
    path = File.join(dir, "fixes.json")
    File.write(path, JSON.generate(data), encoding: "UTF-8")
    path
  end

  # CodeRabbit：前阶段报告里的失败命令必须导致打回（不能借当场全绿蒙混）。
  def test_final_reads_phase_one_report_and_reruns
    Dir.mktmpdir do |dir|
      report_path = write_report(dir, [
        {"id" => "m", "level" => "must_fix", "message" => "锚点不符", "evidence" => "ruby -e \"exit 1\""}
      ])
      fixes_path = write_fixes(dir, {"m" => {"passed" => true, "commit" => "abc"}})
      status, out, = run_cli(["verify", "merge", "10", "39", "--final", "--report", report_path, "--fixes", fixes_path])
      assert_equal 1, status
      data = JSON.parse(out)
      assert_equal "打回", data["conclusion"]
      assert_equal 10, data["pr"], "终验输出应带 pr 可追溯"
    end
  end

  # CodeRabbit：带间接证据的未实测项保留「有条件通过」语义。
  def test_final_conditional_pass_with_indirect_evidence
    Dir.mktmpdir do |dir|
      report_path = write_report(dir, [
        {"id" => "u", "level" => "unverified", "message" => "CI 未跑", "evidence" => "main 上的 run 45004530157 已成功"}
      ])
      fixes_path = write_fixes(dir, {})
      status, out, = run_cli(["verify", "merge", "10", "39", "--final", "--report", report_path, "--fixes", fixes_path])
      assert_equal 0, status
      assert_equal "有条件通过", JSON.parse(out)["conclusion"]
    end
  end

  # #124：终验缺 --report 或 --fixes 在解析阶段 fail-fast。
  def test_final_requires_report_and_fixes
    Dir.mktmpdir do |dir|
      report_path = write_report(dir, [])
      status, out, = run_cli(["verify", "merge", "1", "1", "--final", "--report", report_path])
      assert_equal 2, status
      assert_includes out, "--report"
    end
  end

  def test_next_with_snapshot
    data = snapshot(issues: [issue(1, body: automation(order: [4]))])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["next", "--snapshot", path, "--record", File.join(dir, "run.json")])
      assert_equal 0, status
      assert_equal "claim_issue", JSON.parse(out)["action"]
    end
  end

  def test_invalid_plan_exits_refused
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1])),
      issue(2, body: automation(order: [4, 1]))
    ])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["next", "--snapshot", path, "--record", File.join(dir, "run.json")])
      assert_equal 1, status
      payload = JSON.parse(out)
      assert_equal "invalid_plan", payload["action"]
      refute payload["ok"]
    end
  end

# 独立小修的唯一开工方式：人工点名 claim。claim 不校验 milestone，但要求它是小修。
def test_claim_accepts_small_fix_without_milestone
  data = snapshot(issues: [issue(903, body: automation(order: [4, 1]), milestone: nil, type: "Task")])
  Dir.mktmpdir do |dir|
    path = File.join(dir, "snapshot.json")
    File.write(path, JSON.generate(data), encoding: "UTF-8")
    status, out, = run_cli(["claim", "903", "--snapshot", path, "--record", File.join(dir, "run.json")])
    assert_equal 0, status
    assert_equal "ready", JSON.parse(out)["status"]
  end
end

# 无 milestone 的 Feature 不能认领：那会绕开 milestone 容量与 DAG 检查。
def test_claim_rejects_milestone_less_feature
  data = snapshot(issues: [issue(904, body: automation(order: [4, 1]), milestone: nil, type: "Feature")])
  Dir.mktmpdir do |dir|
    path = File.join(dir, "snapshot.json")
    File.write(path, JSON.generate(data), encoding: "UTF-8")
    status, out, = run_cli(["claim", "904", "--snapshot", path, "--record", File.join(dir, "run.json")])
    assert_equal 1, status
    assert_includes JSON.parse(out)["reasons"].join, "不是独立小修"
  end
end

# 自称小修却带前置：无 milestone 约束 + 声明依赖属矛盾状态，不得豁免。
def test_claim_rejects_small_fix_with_dependencies
  data = snapshot(issues: [
    issue(905, body: automation(order: [4, 1], depends_on: [7]), milestone: nil, type: "Task"),
    issue(7, body: automation(order: [4, 2]), blocked_by: [])
  ])
  Dir.mktmpdir do |dir|
    path = File.join(dir, "snapshot.json")
    File.write(path, JSON.generate(data), encoding: "UTF-8")
    status, out, = run_cli(["claim", "905", "--snapshot", path, "--record", File.join(dir, "run.json")])
    assert_equal 1, status
    assert_includes JSON.parse(out)["reasons"].join, "不是独立小修"
  end
end

  def test_claim_dry_run_does_not_write_record
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["claim", "1", "--snapshot", path, "--record", record])
      assert_equal 0, status
      assert JSON.parse(out)["dry_run"]
      refute File.exist?(record)
    end
  end

  # --apply 需要真实标签写入与回读；此处只验证 dry-run 不落盘，
  # 以及写授权机制本身（见 DryRunGuardTest）。
  def test_claim_apply_claims_only_with_verified_label
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["claim", "1", "--snapshot", path, "--record", record, "--apply",
        "--repo", "invalid/does-not-exist-zzz"])
      # 仓库不可达时不得声称 claimed
      assert_includes [1, 2], status
      payload = JSON.parse(out)
      refute_equal "claimed", payload["claim"]
    end
  end

  # 快照仓库与 --repo 不一致时必须拒绝写入，否则会认领到没校验过的仓库。
  def test_claim_rejects_repo_mismatch
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["claim", "1", "--snapshot", path, "--record", record, "--apply",
        "--repo", "other/repo"])
      assert_equal 2, status
      assert_equal "usage_error", JSON.parse(out)["error"]["code"]
      refute File.exist?(record), "拒绝时不得留下运行记录"
    end
  end

  # 写入失败也要落 aborted，不能让记录停在 claiming。
  def test_claim_write_failure_records_aborted
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")

      # 用假 runner：写 status 抛错，其余按成功返回。
      fake = Class.new(SebasAgents::CommandRunner) do
        def run!(*argv, chdir: Dir.pwd)
          raise SebasAgents::CommandError.new("boom", command: argv) if argv.any? { |arg| arg.start_with?("status=") }

          ""
        end
      end

      cli = SebasAgents::CLI.new(out: StringIO.new, err: StringIO.new)
      cli.define_singleton_method(:runner) { |_options| fake.new(dry_run: false) }
      out = StringIO.new
      cli.instance_variable_set(:@out, out)
      status = cli.run(["claim", "1", "--snapshot", path, "--record", record, "--apply"])
      assert_equal 1, status
      saved = JSON.parse(File.read(record, encoding: "UTF-8"))
      assert_equal "aborted", saved["phase"], "写入失败必须落 aborted"
      assert_equal false, saved["status_written"]
      refute JSON.parse(out.string)["ok"]
    end
  end

  def test_dry_run_blocks_git_writes
    runner = SebasAgents::CommandRunner.new(dry_run: true)
    result = runner.capture("git", "push", "origin", "main")
    assert result.success?
    assert_equal [%w[git push origin main]], runner.calls
  end
end
