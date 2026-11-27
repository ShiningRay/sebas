# frozen_string_literal: true

# 证据闸：Evidence 的 source 段位、trusted bot、正文一致性与 untested 冻结。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class EvidenceGateTest < Minitest::Test
  include SnapshotHelpers

  def test_completed_dependency_without_evidence_blocks
    data = snapshot(issues: [
      issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
      issue(9, body: "", state: "CLOSED", state_reason: "COMPLETED")
    ])
    assert_equal "blocked", select(data).action
  end

  def test_evidence_from_non_maintainer_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9"), state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "random-user"}
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_evidence_from_trusted_bot_unlocks
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      trusted_bots: ["github-actions[bot]"]
    )
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 1, action.issue
  end

  def test_evidence_from_bot_not_in_trusted_list_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "evil-bot[bot]"},
      trusted_bots: ["github-actions[bot]"]
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_bot_cannot_forge_maintainer_source
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "maintainer"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      trusted_bots: ["github-actions[bot]"]
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_workflow_source_without_trusted_bots_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      trusted_bots: []
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_unknown_source_value_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "root"),
          state: "CLOSED", state_reason: "COMPLETED")
      ]
    )
    assert_equal "invalid_plan", select(data).action
  end

  # CR 安全项：作者合法但评论正文没有登记本结论时，不能放行。
  def test_trusted_bot_with_unrelated_comment_body_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => "LGTM, merging soon."},
      trusted_bots: ["github-actions[bot]"]
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_trusted_bot_with_matching_evidence_body_unlocks
    registered = evidence(subject: "issue:9", source: "workflow")
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => registered},
      trusted_bots: ["github-actions[bot]"]
    )
    assert_equal "claim_issue", select(data).action
  end

  def test_evidence_body_with_different_subject_is_invalid
    registered = evidence(subject: "issue:99")
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => registered}
    )
    assert_equal "invalid_plan", select(data).action
  end

  # CR：issue 正文把 untested 改成 [] 不能绕过门禁——必须与登记评论一致。
  def test_evidence_untested_mismatch_is_invalid
    registered = evidence(subject: "issue:9", untested: ["真机 round-trip"])
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        # issue 正文宣称无未实测项
        issue(9, body: evidence(subject: "issue:9", untested: []),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => registered}
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_evidence_untested_match_passes
    registered = evidence(subject: "issue:9", untested: ["真机 round-trip"])
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", untested: ["真机 round-trip"]),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => registered}
    )
    # 登记与正文一致，但仍有未实测项 → 依赖不满足（blocked，而非 invalid）。
    assert_equal "blocked", select(data).action
  end
end
