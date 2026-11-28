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

  # --apply 的真实写入链：租约评论 → status → 标签 → 三项回读。
  # 标签写入失败时不得声称 claimed，且必须落 aborted、把已推进的步骤记进记录，
  # 否则恢复流程会以为远端没动过（重复发租约）。
  def test_claim_apply_claims_only_with_verified_label
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")

      # 假 runner：只让 add_label 失败，其余（评论/status/回读）成功。
      fake = Class.new(SebasAgents::CommandRunner) do
        include RefLockStub

        def run!(*argv, chdir: Dir.pwd)
          # 跨机 ref 锁路由（#306）：claim 写段先拿锁。
          if (write = ref_lock_write(argv))
            return write
          end
          # 时间真实感：status PATCH 成功后单卡读才返回 In progress——
          # 认领前的活状态复查（#306）读的是写前状态，必须不是执行中。
          @status_written = true if argv.include?("-X") && argv.any? { |arg| arg.start_with?("status=") }
          raise SebasAgents::CommandError.new("label boom", command: argv) if argv.include?("--add-label")

          ""
        end

        def json!(*argv, chdir: Dir.pwd)
          if (read = ref_lock_read(argv))
            return read
          end
          joined = argv.join(" ")
          # 租约唯一性预检要读已发评论：返回空数组（尚无租约）。
          return [] if joined.include?("/comments?")

          # 单卡回读（status? / label_present?）的形状必须合法：早先这里写成
          # `joined.exclude?("/comments")`，exclude? 是 ActiveSupport 扩展，
          # 纯 Ruby 下会 NoMethodError——本用例的标签失败路径走不到该行，
          # 静默掩盖了它，但仍属不可达的错误代码。
          status_name = @status_written ? SebasAgents::Model::STATUS_IN_PROGRESS : SebasAgents::Model::STATUS_TODO
          {"status" => {"name" => status_name},
           "labels" => [{"name" => SebasAgents::Model::IN_PROGRESS_LABEL}]}
        end
      end

      cli = SebasAgents::CLI.new(out: StringIO.new, err: StringIO.new)
      cli.define_singleton_method(:runner) { |_options| fake.new(dry_run: false) }
      out = StringIO.new
      cli.instance_variable_set(:@out, out)
      status = cli.run(["claim", "1", "--snapshot", path, "--record", record, "--apply"])
      payload = JSON.parse(out.string)

      refute_equal "claimed", payload["claim"], "标签写入失败不得声称 claimed"
      assert(payload["reasons"].join.include?("label boom"),
        "必须走到标签写入失败路径，而不是替身自身报错：#{payload["reasons"].inspect}")
      assert_equal 1, status
      saved = JSON.parse(File.read(record, encoding: "UTF-8"))
      assert_equal "aborted", saved["phase"]
      assert_equal true, saved["status_written"], "status 已写入的进度必须留痕"
      assert_equal false, saved["label_written"]
    end
  end

  # 快照仓库与 --repo 不一致时必须拒绝写入，否则会认领到没校验过的仓库。
# 回读路径必须被真正执行，且失败只能归因于标签缺失。
#
# 关键是租约回读要**先成功**：若评论列表恒空，lease 那段必然 false，
# 即使实现把 label_present? 从 && 链里删掉，认领照样落同一失败分支，
# 用例仍绿（测不出标签检查有没有执行）。所以让替身记住 POST 出去的
# 租约正文，回读 /comments? 时原样返回——凭据的 lease_id 与运行记录一致，
# 三段回读里只有标签这一环为假。
def test_claim_label_readback_mismatch_records_aborted
  data = snapshot(issues: [issue(1, body: automation)])
  Dir.mktmpdir do |dir|
    path = File.join(dir, "snapshot.json")
    record = File.join(dir, "run.json")
    File.write(path, JSON.generate(data), encoding: "UTF-8")

    fake = Class.new(SebasAgents::CommandRunner) do
      include RefLockStub

      def initialize(*args, **opts)
        super
        @created_lease_body = nil
      end

      def run!(*argv, chdir: Dir.pwd)
        # 跨机 ref 锁路由（#306）：claim 写段先拿锁。
        if (write = ref_lock_write(argv))
          return write
        end
        # 时间真实感（#306）：status PATCH 成功后单卡读才返回 In progress。
        @status_written = true if argv.include?("-X") && argv.any? { |arg| arg.start_with?("status=") }
        # 记下租约评论正文，供后续回读当作既有凭据返回。
        body_arg = argv.find { |arg| arg.to_s.start_with?("body=") }
        @created_lease_body = body_arg.sub(/\Abody=/, "") if body_arg&.include?("sebas-lease")
        ""
      end

      def json!(*argv, chdir: Dir.pwd)
        if (read = ref_lock_read(argv))
          return read
        end
        joined = argv.join(" ")
        if joined.include?("/comments?")
          # 预检阶段尚未发评论 → 空；回读阶段返回刚发出的凭据。
          return [] if @created_lease_body.nil?

          return [{"id" => 900, "user" => {"login" => "ShiningRay"}, "body" => @created_lease_body}]
        end

        # 单卡回读：status 已写入，标签不在——只有这一环为假。
        status_name = @status_written ? SebasAgents::Model::STATUS_IN_PROGRESS : SebasAgents::Model::STATUS_TODO
        {"status" => {"name" => status_name}, "labels" => []}
      end
    end

    cli = SebasAgents::CLI.new(out: StringIO.new, err: StringIO.new)
    cli.define_singleton_method(:runner) { |_options| fake.new(dry_run: false) }
    out = StringIO.new
    cli.instance_variable_set(:@out, out)
    status = cli.run(["claim", "1", "--snapshot", path, "--record", record, "--apply"])
    payload = JSON.parse(out.string)

    assert_equal 1, status
    refute_equal "claimed", payload["claim"], "回读不一致不得声称 claimed"
    # 租约回读通过、status 回读通过，只有 label_present? 为假。
    assert_includes payload["reasons"].join, "readback=false",
      "必须落到回读确认失败，而不是别的分支：#{payload["reasons"].inspect}"
    saved = JSON.parse(File.read(record, encoding: "UTF-8"))
    assert_equal "aborted", saved["phase"]
    assert_equal true, saved["status_written"]
    assert_equal true, saved["label_written"], "写入步骤都成功，失败在回读确认"
  end
end

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
  # 写入失败也要落 aborted，不能让记录停在 claiming。
  def test_claim_write_failure_records_aborted
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")

      # 用假 runner：写 status 抛错，其余按成功返回。
      fake = Class.new(SebasAgents::CommandRunner) do
        include RefLockStub

        def run!(*argv, chdir: Dir.pwd)
          # 跨机 ref 锁路由（#306）：claim 写段先拿锁。
          if (write = ref_lock_write(argv))
            return write
          end
          # 租约唯一性预检要读 issue comments（M4x-WP2）：分页 GET 返回空数组即可。
          if argv.first == "gh" && argv[1] == "api" &&
             argv.any? { |arg| arg.include?("/comments?") } &&
             argv.none? { |arg| %w[-X -f].include?(arg) }
            return "[]"
          end
          # 单卡读（认领前的活状态复查 #306）：写前返回 Todo。
          if argv.first == "gh" && argv[1] == "api" && !argv.include?("-X") &&
             argv[2].to_s.match?(%r{repos/[^/]+/[^/]+/issues/\d+\z})
            return JSON.generate({"status" => {"name" => SebasAgents::Model::STATUS_TODO}, "labels" => []})
          end
          if argv.include?("-X") && argv.any? { |arg| arg.start_with?("status=") }
            raise SebasAgents::CommandError.new("boom", command: argv)
          end
          ""
        end

        def json!(*argv, chdir: Dir.pwd)
          read = ref_lock_read(argv)
          return read if read

          super
        end
      end

      cli = SebasAgents::CLI.new(out: StringIO.new, err: $stderr)
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
  # 容量 >1：在途卡未达容量时第二张可认领；容量 1 保持全仓单卡语义。
  # Q4=A 强制：两张卡都要声明互不重叠的 scope，否则缺 scope 独占容量。
  def test_claim_allows_second_card_within_capacity
    data = snapshot(issues: [
      issue(1, body: automation(scope: ["src/store/"]), status: "In progress"),
      issue(2, body: automation(order: [4, 2], scope: ["src/keys/"]))
    ], capacity: 2)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["claim", "2", "--snapshot", path, "--record", File.join(dir, "run.json")])
      assert_equal 0, status
      payload = JSON.parse(out)
      assert payload["ok"]
      assert_equal "ready", payload["status"]
    end
  end

  def test_claim_refuses_when_capacity_exhausted
    data = snapshot(issues: [
      issue(1, body: automation(scope: ["src/store/"]), status: "In progress"),
      issue(2, body: automation(order: [4, 2], scope: ["src/keys/"]), status: "In progress"),
      issue(3, body: automation(order: [4, 3], scope: ["docs/"]))
    ], capacity: 2)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["claim", "3", "--snapshot", path, "--record", File.join(dir, "run.json")])
      assert_equal 1, status
      assert_includes JSON.parse(out)["reasons"].join, "达到容量 2"
    end
  end

  # resume 按有效容量校验活动卡数：容量 2 下持有两张卡可续跑自己的那张；
  # 超过容量拒绝。
  def test_resume_allows_second_card_within_capacity
    data = snapshot(issues: [
      issue(1, body: automation, status: "In progress"),
      issue(2, body: automation(order: [4, 2]), status: "In progress")
    ], capacity: 2)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      File.write(record, JSON.generate({"issue" => 2, "phase" => "claimed", "schema" => 2}), encoding: "UTF-8")
      status, out, = run_cli(["resume", "2", "--snapshot", path, "--record", record])
      assert_equal 0, status
      payload = JSON.parse(out)
      assert payload["ok"]
      assert_equal "resume_issue", payload["action"]
    end
  end

  def test_resume_refuses_when_capacity_exhausted
    data = snapshot(issues: [
      issue(1, body: automation, status: "In progress"),
      issue(2, body: automation(order: [4, 2]), status: "In progress"),
      issue(3, body: automation(order: [4, 3]), status: "In progress")
    ], capacity: 2)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      File.write(record, JSON.generate({"issue" => 3, "phase" => "claimed", "schema" => 2}), encoding: "UTF-8")
      status, out, = run_cli(["resume", "3", "--snapshot", path, "--record", record])
      assert_equal 1, status
      assert_includes JSON.parse(out)["error"]["message"], "达到容量 2"
    end
  end

  # 默认记录损坏不得被静默当成「无遗留」放行容量：即使走显式 --record，
  # 读取默认记录失败也拒绝命令（fail-closed）。
  def test_claim_refuses_when_default_record_corrupt
    data = snapshot(issues: [issue(1, body: automation)], capacity: 2)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      sebas_dir = File.join(dir, ".sebas-agent")
      Dir.mkdir(sebas_dir)
      File.write(File.join(sebas_dir, "run.json"), "{not json", encoding: "UTF-8")
      Dir.chdir(dir) do
        status, out, = run_cli(["claim", "1", "--snapshot", path, "--record", File.join(dir, "run.json")])
        refute_equal 0, status
      end
    end
  end

  # aborted 遗留记录是认领未确认的异常态（F3/F4）：claim --apply 的迁移
  # 不得自动搬走它解除容量钳制——认领被拒，记录原地保留待人工对账。
  def test_claim_refuses_when_legacy_aborted_record_unreconciled
    data = snapshot(issues: [
      issue(1, body: automation, status: "In progress"),
      issue(2, body: automation(order: [4, 2]))
    ], capacity: 2)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      sebas_dir = File.join(dir, ".sebas-agent")
      Dir.mkdir(sebas_dir)
      legacy = File.join(sebas_dir, "run.json")
      File.write(legacy, JSON.generate(
        {"issue" => 1, "phase" => "aborted", "status_written" => true, "schema" => 1}
      ), encoding: "UTF-8")
      Dir.chdir(dir) do
        # --apply 才触发迁移（CR-0 只读路径不迁移）；迁移在可认领性判定前
        # 执行，aborted 记录即在此处被拒。
        status, out, = run_cli(["claim", "2", "--snapshot", path, "--apply"])
        assert_equal 1, status
        assert_includes JSON.parse(out)["error"]["message"], "aborted"
        # 记录原地保留，迁移窗口（容量钳制）不解除
        assert File.exist?(legacy)
        assert_equal 1, JSON.parse(File.read(legacy, encoding: "UTF-8"))["schema"]
      end
    end
  end

end
