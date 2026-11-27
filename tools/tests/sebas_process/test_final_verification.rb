# frozen_string_literal: true

# 终验：must_fix 收口、条目 id 分配与 fixes 键匹配、checker 复跑、结论映射。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class FinalVerificationTest < Minitest::Test
  # 只根据 fix 是否命中返回结果，用于测 fixes 键匹配本身；
  # checker 的重执行行为由 VerifyChecksTest 覆盖。
  HIT = ->(_item, fix) { fix.is_a?(Hash) ? {passed: true, reason: "命中"} : {passed: false, reason: "未命中"} }

  def verification_with(items)
    report = SebasAgents::VerificationReport.new
    items.each do |level, message|
      report.public_send(level, message)
    end
    report
  end

  def final(report, fixes)
    SebasAgents::Verifier.final_verification(report, fixes, checker: HIT)
  end

  def test_unresolved_must_fix_blocks
    report = verification_with([["must_fix", "锚点不符"]])
    refute final(report, {}).pass?
    assert_equal "打回", final(report, {}).conclusion
  end

  def test_verifier_blocker_propagates
    report = verification_with([["blocker", "缺文件"]])
    assert_equal "打回", final(report, {}).conclusion
  end

  # #109：fixes 用条目自身 id 也要能匹配，不能只认 level 自编号。
  def test_fixes_keyed_by_item_id_matches
    report = SebasAgents::VerificationReport.new
    report.must_fix("锚点不符", id: "g")
    fixes = {"g" => {"passed" => true, "commit" => "abc"}}
    assert final(report, fixes).pass?
  end

  def test_item_id_kept_in_report
    report = SebasAgents::VerificationReport.new
    report.must_fix("锚点不符", id: "r2-1")
    assert_equal "r2-1", report.items.first.id
  end

  def test_auto_id_is_per_level
    report = SebasAgents::VerificationReport.new
    report.must_fix("a")
    report.acceptable("b")
    report.must_fix("c")
    assert_equal %w[must_fix-1 acceptable-1 must_fix-2], report.items.map(&:id)
  end

  # CR：显式 id 与生成的 fallback id 不得碰撞。
  def test_explicit_id_does_not_collide_with_generated
    report = SebasAgents::VerificationReport.new
    report.must_fix("a")
    report.must_fix("b", id: "must_fix-2")
    report.must_fix("c")
    assert_equal %w[must_fix-1 must_fix-2 must_fix-3], report.items.map(&:id)
    assert_equal 3, report.items.map(&:id).uniq.length
  end

  def test_duplicate_explicit_id_is_rejected
    report = SebasAgents::VerificationReport.new
    report.must_fix("a", id: "g")
    assert_raises(ArgumentError) { report.must_fix("b", id: "g") }
  end

  # CR：positional fallback 按 level 内序号，不由 id 后缀推断。
  def test_positional_fallback_is_not_derived_from_id_suffix
    report = SebasAgents::VerificationReport.new
    report.must_fix("a", id: "r2-1")
    report.must_fix("b", id: "r3-1")
    fixes = {"must_fix-1" => {"passed" => true, "commit" => "aaa"}}
    # 只有第 1 项被覆盖，第 2 项必须仍算未修复。
    assert_equal "打回", final(report, fixes).conclusion
  end

  # CR：level-only 简写只在同 level 唯一时生效。
  def test_level_only_fix_requires_unique_item
    two = SebasAgents::VerificationReport.new
    two.must_fix("a")
    two.must_fix("b")
    fixes = {"must_fix" => {"passed" => true, "commit" => "aaa"}}
    assert_equal "打回", final(two, fixes).conclusion

    one = SebasAgents::VerificationReport.new
    one.must_fix("a")
    assert final(one, fixes).pass?
  end

  # CR：位置键不能命中另一条目的显式 id，否则一条 fix 满足两项。
  def test_positional_key_does_not_shadow_other_item_explicit_id
    report = SebasAgents::VerificationReport.new
    report.must_fix("a", id: "must_fix-2")   # 显式 id 恰好等于第二项的位置键
    report.must_fix("b", id: "g")
    fixes = {"must_fix-2" => {"passed" => true, "commit" => "aaa"}}
    # 第 1 项按显式 id 命中；第 2 项的位置键 must_fix-2 被占用，不得复用 → 仍算未修复。
    assert_equal "打回", final(report, fixes).conclusion
  end

  # CR：level-only 简写同样不能命中另一条目的显式 id。
  def test_level_only_key_does_not_shadow_other_item_explicit_id
    report = SebasAgents::VerificationReport.new
    report.must_fix("a", id: "acceptable")
    report.acceptable("b", id: "g")
    fixes = {"acceptable" => {"passed" => true, "commit" => "abc", "reason_still_valid" => true}}
    # "acceptable" 是第 1 项的显式 id，第 2 项不得再借它过关。
    assert_equal "打回", final(report, fixes).conclusion
  end

  # #124：自报修复不再构成有条件通过——checker 判失败时结论必须是打回。
  def test_self_reported_fix_with_failing_checker_is_rejected
    report = SebasAgents::VerificationReport.new
    report.must_fix("锚点不符", evidence: "ruby -e \"exit 1\"")
    fixes = {"must_fix-1" => {"passed" => true, "commit" => "abc"}}
    checker = ->(item, fix) { SebasAgents::VerifyChecks.rerun(item, fix, root: Dir.pwd) }
    result = SebasAgents::Verifier.final_verification(report, fixes, checker: checker)
    refute result.pass?, "自报 passed:true 但复跑失败必须打回"
    assert_equal "打回", result.conclusion
  end

  # #124：checker 不可省——省略（生产路径旧调用形态）必须显式失败，不得静默降级。
  def test_checker_is_required
    report = verification_with([["must_fix", "锚点不符"]])
    assert_raises(ArgumentError) do
      SebasAgents::Verifier.final_verification(report, {})
    end
  end
end

class VerifyChecksTest < Minitest::Test
  def item_with(evidence)
    report = SebasAgents::VerificationReport.new
    report.must_fix("占位", evidence: evidence)
    report.must_fix_items.first
  end

  def test_reruns_command_and_passes_on_success
    result = SebasAgents::VerifyChecks.rerun(item_with("ruby -e \"exit 0\""), {})
    assert result[:passed], result[:reason].to_s
  end

  # 验收用例：fixes 写 passed:true 但实际检查失败 → 必须打回。
  def test_reruns_command_and_fails_on_failure_despite_self_report
    result = SebasAgents::VerifyChecks.rerun(item_with("ruby -e \"exit 1\""), {"passed" => true, "commit" => "abc"})
    refute result[:passed], "自报 passed:true 不能骗过 checker"
    assert_includes result[:reason].to_s, "复跑失败"
  end

  def test_empty_evidence_rejects
    result = SebasAgents::VerifyChecks.rerun(item_with(""), {"passed" => true})
    refute result[:passed]
    assert_equal "无可复跑检查", result[:reason]
  end

  def test_non_whitelisted_bin_rejects
    result = SebasAgents::VerifyChecks.rerun(item_with("curl http://example.com"), {})
    refute result[:passed]
    assert_match(/白名单/, result[:reason].to_s)
  end

  def test_git_write_subcommand_rejects
    result = SebasAgents::VerifyChecks.rerun(item_with("git push origin main"), {})
    refute result[:passed]
    assert_match(/只读/, result[:reason].to_s)
  end

  # CodeRabbit：config/remote/symbolic-ref 有写形态且无法按参数区分读写，直接排除。
  # 断言 allowed? 本身（不真跑），否则白名单若回归放行，
  # git 自身的执行失败也会让 rerun 返回 passed:false，测试区分不出拒绝分支。
  def test_git_writable_read_listed_subcommands_reject
    require "shellwords"
    %w[config remote symbolic-ref].each do |subcommand|
      reason = SebasAgents::VerifyChecks.allowed?(Shellwords.split("git #{subcommand} HEAD"))
      refute_equal true, reason, "git #{subcommand} 不应进入白名单：#{reason.inspect}"
    end
  end

  # gh 白名单判定不真跑（不依赖网络）：只测 allowed? 本身。
  def test_gh_view_is_allowed_but_edit_is_not
    require "shellwords"
    assert_equal true, SebasAgents::VerifyChecks.allowed?(Shellwords.split("gh pr view 1 --repo a/b"))
    refute_equal true, SebasAgents::VerifyChecks.allowed?(Shellwords.split("gh pr edit 1 --repo a/b"))
  end

  # 不经 shell：`;` 后的片段不会成为第二条命令；解析后仍受白名单约束。
  def test_shell_metacharacters_do_not_create_second_command
    require "shellwords"
    argv = SebasAgents::VerifyChecks.parse("crystal spec; rm -rf /")
    assert_equal ["crystal", "spec;", "rm", "-rf", "/"], argv
    # 以 argv 语义执行 crystal 时，"spec;" 只会作为非法参数，rm 不会被调用。
  end
end

class VerdictMappingTest < Minitest::Test
  def test_chinese_verdicts_map_to_levels
    expected = {
      "阻断" => "blocker",
      "应修" => "must_fix",
      "可留" => "acceptable",
      "未实测" => "unverified",
      "通过" => "ok"
    }
    expected.each do |verdict, level|
      assert_equal level, SebasAgents::VerificationReport::VERDICTS.fetch(verdict), "映射 #{verdict}"
    end
  end

  def test_english_levels_pass_through
    %w[blocker must_fix acceptable unverified ok pass].each do |level|
      refute_nil SebasAgents::VerificationReport::VERDICTS[level], "缺少 #{level}"
    end
  end
end
