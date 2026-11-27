# frozen_string_literal: true

# Verifier 缺陷回归（阻断 15、应修 2、#107）：锚点越界、失败检查阻断、
# 合并前模式与证据来源可信度。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class VerifierRegressionTest < Minitest::Test
  include SnapshotHelpers

  # 阻断 15：锚点越界
  def test_anchor_line_out_of_range_is_blocker
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "x.cr"), "line1\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_code_anchors(
        [{"file" => "src/x.cr", "line" => 999, "content" => "line1"}], root: dir
      )
      refute report.pass?
      assert_equal 1, report.blockers.length
    end
  end

  def test_anchor_line_zero_is_blocker
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "x.cr"), "line1\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_code_anchors(
        [{"file" => "src/x.cr", "line" => 0, "content" => "line1"}], root: dir
      )
      refute report.pass?
    end
  end

  def test_anchor_without_content_is_blocker
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "x.cr"), "line1\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_code_anchors(
        [{"file" => "src/x.cr", "line" => 1}], root: dir
      )
      refute report.pass?
    end
  end

  # 应修 2：失败检查必须阻断
  def test_verify_merge_blocks_on_failing_checks
    data = snapshot(
      issues: [issue(39, body: automation, state: "CLOSED", state_reason: "COMPLETED")],
      pull_requests: [{
        "number" => 10, "state" => "MERGED", "closing_issues" => [39],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "FAILURE"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data))
    refute report.pass?
  end

  # #107：合并前模式不能因为「未合并 / 未关闭」而必然失败。
  # 但仍须满足可提前判定的条件：Evidence accepted + thread 清空 + CI 全绿。
  def test_verify_merge_pre_passes_when_ci_green
    body = automation + evidence(subject: "issue:39", merged: false)
    data = snapshot(
      issues: [issue(39, body: body, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39], "review_threads" => [],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    assert report.pass?, report.items.map(&:message).inspect
  end

  def test_verify_merge_post_blocks_when_not_merged
    data = snapshot(
      issues: [issue(39, body: automation, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data))
    refute report.pass?
    assert(report.blockers.any? { |b| b.message.include?("未合并") })
  end

  # 必须带齐 Evidence 与干净 thread，否则「缺证据」也会让 pass? 为假，
  # 删掉失败 CI 的阻断逻辑用例照样绿（假通过）。
  def test_verify_merge_pre_still_blocks_on_failing_ci
    data = snapshot(
      issues: [issue(39, body: automation + evidence(subject: "issue:39", merged: false), state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39], "review_threads" => [],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "FAILURE"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?
    assert(report.blockers.any? { |b| b.message.include?("存在失败检查") },
      "必须是失败 CI 阻断，而不是缺证据：#{report.items.map(&:message).inspect}")
  end

  def test_verify_merge_pre_blocks_when_issue_already_closed
    data = snapshot(
      issues: [issue(39, body: automation, state: "CLOSED", state_reason: "COMPLETED")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?
    assert(report.blockers.any? { |b| b.message.include?("已关闭") }, report.items.map(&:message).inspect)
  end

  # #107 核心：合并前自检必须覆盖 Evidence 与 review thread。
  def test_verify_merge_pre_blocks_without_evidence
    data = snapshot(
      issues: [issue(39, body: automation, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39], "review_threads" => [],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?
    assert(report.blockers.any? { |b| b.message.include?("缺 Evidence") }, report.items.map(&:message).inspect)
  end

  def test_verify_merge_pre_blocks_with_unresolved_threads
    body = automation + evidence(subject: "issue:39", merged: false)
    data = snapshot(
      issues: [issue(39, body: body, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39],
        "review_threads" => [{"id" => "t1", "is_resolved" => false}],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?
    assert(report.blockers.any? { |b| b.message.include?("未解决 review thread") }, report.items.map(&:message).inspect)
  end

  def test_verify_merge_pre_blocks_on_untested_items
    body = automation + evidence(subject: "issue:39", untested: ["真机 round-trip"])
    data = snapshot(
      issues: [issue(39, body: body, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39], "review_threads" => [],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?
    assert(report.blockers.any? { |b| b.message.include?("未实测") }, report.items.map(&:message).inspect)
  end

  def test_verify_merge_pre_passes_with_evidence_and_clean_threads
    body = automation + evidence(subject: "issue:39", merged: false)
    data = snapshot(
      issues: [issue(39, body: body, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39], "review_threads" => [],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    assert report.pass?, report.items.map(&:message).inspect
  end

  # CR：checks 为空说明快照没取到 CI 结果，不能当成「没有失败 = 全绿」放行。
  def test_verify_merge_pre_blocks_when_no_checks_recorded
    body = automation + evidence(subject: "issue:39", merged: false)
    data = snapshot(
      issues: [issue(39, body: body, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39], "review_threads" => [],
        "checks" => []
      }]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?, "空 checks 必须阻断"
    assert(report.blockers.any? { |b| b.message.include?("没有任何 CI 检查记录") },
      report.items.map(&:message).inspect)
  end

  # CR 安全项：--pre 不能只看 status 字段，必须走 trusted? 授权校验。
  def test_verify_merge_pre_blocks_on_untrusted_evidence_source
    body = automation + evidence(subject: "issue:39", merged: false)
    data = snapshot(
      issues: [issue(39, body: body, state: "OPEN")],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39], "review_threads" => [],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
      }],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "random-user"}
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true)
    refute report.pass?
    assert(report.blockers.any? { |b| b.message.include?("未由 Maintainer 或受信 bot 登记") },
      report.items.map(&:message).inspect)
  end
end
