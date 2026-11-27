# frozen_string_literal: true

# RunRecord 的 schema 迁移与租约写守卫（M4x-Parallel-WP2，#220）。
#
# 迁移窗口的安全属性：非活动记录可自动升级，活动记录必须人工确认——
# 自动迁移一张正在被认领的卡，等于把两个 worker 放到同一张卡上。
#
# 写守卫：租约评论的 post/update 必须落在既有 create_comment /
# update_comment 的放行正则内，其余 gh 写命令仍被拦截。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class RunRecordMigrationTest < Minitest::Test
  def test_inactive_v1_record_auto_migrates_and_old_path_removed
    Dir.mktmpdir do |dir|
      legacy = File.join(dir, "run.json")
      File.write(legacy, JSON.generate({
        "schema" => 1, "issue" => 7, "branch" => "feat/7", "phase" => "released", "attempts" => 1
      }), encoding: "UTF-8")

      migrated = SebasAgents::RunRecord.migrate_legacy!(legacy, runs_dir: File.join(dir, "runs"))
      assert migrated
      refute File.exist?(legacy), "旧路径必须删除（搬迁并双读一个版本）"
      target = File.join(dir, "runs", "7.json")
      assert File.exist?(target)
      data = JSON.parse(File.read(target, encoding: "UTF-8"))
      assert_equal 2, data["schema"]
      assert_equal "released", data["phase"]
    end
  end

  def test_active_v1_record_fail_closed_requires_manual_confirmation
    Dir.mktmpdir do |dir|
      legacy = File.join(dir, "run.json")
      File.write(legacy, JSON.generate({
        "schema" => 1, "issue" => 7, "branch" => "feat/7", "phase" => "claimed", "attempts" => 0
      }), encoding: "UTF-8")

      error = assert_raises(SebasAgents::InvalidPlan) do
        SebasAgents::RunRecord.migrate_legacy!(legacy, runs_dir: File.join(dir, "runs"))
      end
      assert_includes error.message, "人工确认"
      assert File.exist?(legacy), "fail-closed：旧记录不得被吞"
    end
  end

  def test_active_records_enforces_schema_2
    Dir.mktmpdir do |dir|
      runs = File.join(dir, "runs")
      FileUtils.mkdir_p(runs)
      File.write(File.join(runs, "7.json"), JSON.generate({
        "schema" => 2, "issue" => 7, "phase" => "claimed"
      }), encoding: "UTF-8")
      assert_equal 7, SebasAgents::RunRecord.active_records(runs).first["issue"]

      # schema 非 2 → invalid_plan（CR-10：未知 schema 一律拒绝）
      File.write(File.join(runs, "8.json"), JSON.generate({"schema" => 1, "issue" => 8, "phase" => "released"}),
        encoding: "UTF-8")
      assert_raises(SebasAgents::InvalidPlan) { SebasAgents::RunRecord.active_records(runs) }
      File.write(File.join(runs, "8.json"), JSON.generate({"schema" => 99, "issue" => 8, "phase" => "claimed"}),
        encoding: "UTF-8")
      assert_raises(SebasAgents::InvalidPlan) { SebasAgents::RunRecord.active_records(runs) }
    end
  end

  # 必须打真实的 CLI#record_for：若在本文件复刻一段容量判断，删掉生产判断后
  # 复刻版照样抛异常，用例仍绿（假通过）。
  #
  # record_for 的路径是 CWD 相对的（RunRecord::RUNS_DIR / DEFAULT_PATH），
  # 因此把夹具按真实布局摆进临时目录再 chdir 进去，且不传 record 选项
  # （传了会走 explicit.load 提前返回）。
  def test_migration_window_capacity_one_invalid_plan_on_multi_active
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        # 按生产布局摆：RunRecord::RUNS_DIR / DEFAULT_PATH 都相对 CWD。
        runs = File.join(dir, SebasAgents::RunRecord::RUNS_DIR)
        FileUtils.mkdir_p(runs)
        File.write(File.join(runs, "7.json"),
          JSON.generate({"schema" => 2, "issue" => 7, "phase" => "claimed"}), encoding: "UTF-8")
        File.write(File.join(runs, "8.json"),
          JSON.generate({"schema" => 2, "issue" => 8, "phase" => "claimed"}), encoding: "UTF-8")
        legacy = File.join(dir, SebasAgents::RunRecord::DEFAULT_PATH)
        File.write(legacy, JSON.generate({"schema" => 2, "issue" => 99, "phase" => "claimed"}),
          encoding: "UTF-8")

        cli = SebasAgents::CLI.new(out: StringIO.new, err: StringIO.new)

        # 迁移窗口（legacy run.json 在场）内两份活动记录 → 容量 1 → invalid_plan
        error = assert_raises(SebasAgents::InvalidPlan) { cli.send(:record_for, {}) }
        assert_includes error.message, "迁移期容量"

        # 旧记录撤掉即离开迁移窗口：同样两份活动记录应正常取到首份（不再报错）。
        FileUtils.rm(legacy)
        assert_equal 7, cli.send(:record_for, {})["issue"]
      end
    end
  end

end
class LeaseWriteGuardTest < Minitest::Test
  RUNNER = SebasAgents::CommandRunner

  def assert_allowed(intent, command_string)
    pattern = RUNNER::ALLOWED_WRITES[intent]
    assert !pattern.nil? && pattern.match?(command_string),
      "#{intent} 应放行：#{command_string}"
  end

  def assert_blocked(command_string)
    intents = %i[add_label remove_label set_status set_type create_comment update_comment pin_comment]
    matched = intents.any? do |intent|
      pattern = RUNNER::ALLOWED_WRITES[intent]
      !pattern.nil? && pattern.match?(command_string)
    end
    refute matched, "应被拦截：#{command_string}"
  end

  def test_lease_comment_post_matches_create_comment_intent
    assert_allowed :create_comment,
      "gh api repos/o/r/issues/1/comments -f body=#{SebasAgents::Lease::MARKER}\nlease"
  end

  def test_lease_comment_update_matches_update_comment_intent
    assert_allowed :update_comment,
      "gh api -X PATCH repos/o/r/issues/comments/900 -f body=#{SebasAgents::Lease::MARKER}\nreleased"
  end

  def test_unrelated_gh_writes_still_blocked
    assert_blocked "gh api -X DELETE repos/o/r/issues/comments/900"
    assert_blocked "gh issue close 1 --repo o/r"
  end

end
