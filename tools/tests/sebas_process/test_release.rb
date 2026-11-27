# frozen_string_literal: true

# Release 计划：fix 才发 patch、feat 阻断、smoke 输出校验。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class ReleaseTest < Minitest::Test
  def test_fix_only_bumps_patch
    plan = SebasAgents::Release.plan(latest_tag: "v0.1.0", subjects: ["fix(a): b", "docs: c"])
    assert_equal "patch", plan["action"]
    assert_equal "0.1.1", plan["next_version"]
  end

  def test_feat_blocks_patch
    plan = SebasAgents::Release.plan(latest_tag: "v0.1.0", subjects: ["fix(a): b", "feat: d"])
    assert_equal "skip", plan["action"]
  end

  def test_no_fix_is_noop
    plan = SebasAgents::Release.plan(latest_tag: "v0.1.0", subjects: ["docs: c"])
    assert_equal "noop", plan["action"]
  end

  def test_scoped_fix_matches
    plan = SebasAgents::Release.plan(latest_tag: "v1.2.9", subjects: ["fix(orchestration): x"])
    assert_equal "1.2.10", plan["next_version"]
  end

  # 冒烟输出自 v0.1.0 起带构建 git rev：`sebas X.Y.Z (<rev>)`。
  def test_smoke_output_accepts_build_rev
    assert SebasAgents::Release.smoke_output_matches?("0.1.1", "sebas 0.1.1")
    assert SebasAgents::Release.smoke_output_matches?("0.1.1", "sebas 0.1.1 (abc1234def56)")
    assert SebasAgents::Release.smoke_output_matches?("0.1.1", "sebas 0.1.1 (unknown)")
    assert SebasAgents::Release.smoke_output_matches?("0.1.1", "sebas 0.1.1 (abc1234def56)\n")
  end

  def test_smoke_output_rejects_mismatch
    refute SebasAgents::Release.smoke_output_matches?("0.1.1", "sebas 0.1.2 (abc1234)")
    refute SebasAgents::Release.smoke_output_matches?("0.1.1", "sebas 0.1.1 (abc) extra")
    refute SebasAgents::Release.smoke_output_matches?("0.1.1", "sebas 0.1.00")
    refute SebasAgents::Release.smoke_output_matches?("0.1.1", "")
  end
end
