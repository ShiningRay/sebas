# frozen_string_literal: true

# Verifier 的合并前自检（--pre）：两阶段块、CI 读数、review thread 与伪造合并。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class VerifierPreTest < Minitest::Test
  include SnapshotHelpers

  def pre_data(issue_body:, pr_extra: {}, issue_state: "OPEN")
    snapshot(
      issues: [issue(39, body: issue_body, state: issue_state)],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}],
        "review_threads" => []
      }.merge(pr_extra)],
      trusted_bots: ["github-actions[bot]"],
      source_authors: {
        "https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"
      },
      source_bodies: {
        "https://github.com/o/r/issues/1#issuecomment-1" => evidence(
          subject: "issue:39", merged: false, source: "workflow"
        )
      }
    )
  end

  def run_pre(data)
    SebasAgents::Verifier.verify_merge(
      10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true
    )
  end

  # 两阶段登记的合并前块：merged_into_main=false 且无 merge_commit，应通过。
  def test_pre_passes_with_two_phase_block
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    report = run_pre(pre_data(issue_body: body))
    assert report.pass?, "合并前块应通过，实际 blocked: #{report.blockers.map(&:message)}"
  end

  # 未合并却声称 merged_into_main=true：伪造，必须阻断。
  def test_pre_blocks_when_block_claims_merged
    body = automation + evidence(subject: "issue:39", merged: true, source: "workflow")
    report = run_pre(pre_data(issue_body: body))
    refute report.pass?
    messages = report.blockers.map(&:message).join("\n")
    assert_includes messages, "声称 merged_into_main=true"
  end

  def test_pre_blocks_without_evidence
    report = run_pre(pre_data(issue_body: automation))
    refute report.pass?
    assert(report.blockers.map(&:message).any? { |m| m.include?("缺 Evidence") })
  end

  def test_pre_blocks_on_unresolved_thread
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    data = pre_data(issue_body: body, pr_extra: {"review_threads" => [{"isResolved" => false}]})
    report = run_pre(data)
    refute report.pass?
    assert(report.blockers.map(&:message).any? { |m| m.include?("未解决 review thread") })
  end

  # 空 checks 不能算「全绿」。
  def test_pre_blocks_on_empty_checks
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    data = pre_data(issue_body: body, pr_extra: {"checks" => []})
    report = run_pre(data)
    refute report.pass?
    assert(report.blockers.map(&:message).any? { |m| m.include?("没有任何 CI 检查记录") })
  end

  # 只收到第三方审阅的 check 不是门禁读数：与空 checks 同口径阻断，
  # 否则「没看见 CI」会被当成「全绿」。
  def test_pre_blocks_when_only_advisory_checks_present
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    data = pre_data(issue_body: body, pr_extra: {
      "checks" => [{"name" => "CodeRabbit", "status" => "IN_PROGRESS", "conclusion" => nil}]
    })
    report = run_pre(data)
    refute report.pass?
    assert(report.blockers.map(&:message).any? { |m| m.include?("没有任何 CI 检查记录") })
  end

  # advisory 进行中不拦合并前门禁：权威是未解决 review thread（上一条测试），
  # 而不是第三方 check 的进度。
  def test_pre_passes_with_pending_advisory_check
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    data = pre_data(issue_body: body, pr_extra: {
      "checks" => [
        {"name" => "spec / ubuntu-latest", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
        {"name" => "CodeRabbit", "status" => "IN_PROGRESS", "conclusion" => nil}
      ]
    })
    report = run_pre(data)
    assert report.pass?, "advisory pending 应通过，实际 blocked: #{report.blockers.map(&:message)}"
  end
end
