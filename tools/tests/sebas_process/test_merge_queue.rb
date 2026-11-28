# frozen_string_literal: true

# 合并队列规划（M4x-Parallel-WP3，#221；Proposal §7.2）。
#
# 队列只做确定性规划：给定逐租约动作表与快照，算出队首 PR 在链上的下一步。
# 不发任何写——执行仍是 coordinator 逐条跑命令。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class MergeQueueTest < Minitest::Test
  include SnapshotHelpers

  def pr(number:, issue:, state: "OPEN", merge_state: "CLEAN", checks: [], threads: [],
    base: "main", head: "sha#{number}", body: nil, merged: false)
    {
      "number" => number,
      "head_ref_name" => "feat/#{issue}",
      "base_ref_name" => base,
      "head_sha" => head,
      "state" => state,
      "merged" => merged,
      "merge_state_status" => merge_state,
      "checks" => checks,
      "closing_issues" => [issue],
      "review_threads" => threads,
      "body" => body
    }
  end

  def lease(issue:, pr:, action: "merge_ready", owned: true)
    SebasAgents::Policy::Selection::LeaseAction.new(
      issue: issue, action: action, reason: "t", pr: pr, owned: owned)
  end

  def snap_with(prs)
    SebasAgents::Model::Snapshot.from_hash(snapshot(issues: [], pull_requests: prs))
  end

  # 默认把所有 PR 的当前 head 视为「已核验」：本文件的用例大多在测链上其他
  # 环节，不该每条都重述核验绑定。需要测核验绑定的用例显式传 verified_heads。
  def plan(leases, prs, changelog: nil, verified_heads: nil)
    heads = verified_heads || prs.to_h { |item| [item["number"], item["head_sha"]] }
      .then { |by_pr| leases.to_h { |item| [item.issue, by_pr[item.pr]] } }
    SebasAgents::MergeQueue.plan(leases, snap_with(prs), changelog: changelog,
      verified_heads: heads)
  end

  # --- 链上步骤 ---

  def test_empty_queue
    queue = plan([], [])
    assert queue.empty?
    assert_nil queue.head
  end

  def test_clean_pr_goes_straight_to_merge
    prs = [pr(number: 50, issue: 1)]
    queue = plan([lease(issue: 1, pr: 50)], prs)
    assert_equal 1, queue.head
    assert_equal "merge", queue.step
    assert_includes queue.blocked_by, "--match-head-commit sha50"
  end

  def test_only_merge_ready_leases_enter_queue
    prs = [pr(number: 50, issue: 1), pr(number: 51, issue: 2)]
    queue = plan([
      lease(issue: 1, pr: 50, action: "resume_pr"),
      lease(issue: 2, pr: 51)
    ], prs)
    assert_equal [2], queue.entries.map { |entry| entry.issue }
  end

  def test_failed_checks_block_at_verify
    prs = [pr(number: 50, issue: 1,
      checks: [{"name" => "spec / ubuntu-latest", "status" => "COMPLETED", "conclusion" => "FAILURE"}])]
    queue = plan([lease(issue: 1, pr: 50)], prs)
    assert_equal "verify_pre", queue.step
    assert_includes queue.blocked_by, "失败检查"
  end

  def test_pending_checks_block_at_verify
    prs = [pr(number: 50, issue: 1,
      checks: [{"name" => "spec / ubuntu-latest", "status" => "IN_PROGRESS", "conclusion" => nil}])]
    queue = plan([lease(issue: 1, pr: 50)], prs)
    assert_equal "verify_pre", queue.step
    assert_includes queue.blocked_by, "未完成的检查"
  end

  def test_unresolved_threads_block_at_verify
    prs = [pr(number: 50, issue: 1, threads: [{"isResolved" => false}])]
    queue = plan([lease(issue: 1, pr: 50)], prs)
    assert_equal "verify_pre", queue.step
    assert_includes queue.blocked_by, "review thread"
  end

  def test_wrong_base_blocks_at_verify
    prs = [pr(number: 50, issue: 1, base: "release/0.2")]
    queue = plan([lease(issue: 1, pr: 50)], prs)
    assert_equal "verify_pre", queue.step
    assert_includes queue.blocked_by, "只允许 main"
  end

  def test_closed_not_merged_needs_human_decision
    prs = [pr(number: 50, issue: 1, state: "CLOSED")]
    queue = plan([lease(issue: 1, pr: 50)], prs)
    assert_equal "verify_pre", queue.step
    assert_includes queue.blocked_by, "人工裁决"
  end

  def test_merged_pr_awaits_evidence_then_release
    prs = [pr(number: 50, issue: 1, state: "MERGED", merged: true)]
    queue = plan([lease(issue: 1, pr: 50)], prs)
    assert_equal "release", queue.step
    assert_includes queue.blocked_by, "Evidence"
  end

  # --- CHANGELOG 队列追加（scribe.md §5 修订）---

  def test_changelog_block_requires_append_before_merge
    body = <<~MD
      正文
      #{SebasAgents::MergeQueue::CHANGELOG_MARKER}
      ```
      - **条目一**
      - **条目二**
      ```
    MD
    prs = [pr(number: 50, issue: 1, body: body)]
    queue = plan([lease(issue: 1, pr: 50)], prs, changelog: "## [Unreleased]\n")
    assert_equal "changelog", queue.step
    assert_equal 2, queue.entries.first.changelog_pending.length
  end

  def test_changelog_already_recorded_lets_queue_merge
    body = "#{SebasAgents::MergeQueue::CHANGELOG_MARKER}\n```\n- 条目 (#50)\n```\n"
    prs = [pr(number: 50, issue: 1, body: body)]
    queue = plan([lease(issue: 1, pr: 50)], prs, changelog: "## [Unreleased]\n\n- 条目 (#50)\n")
    assert_equal "merge", queue.step
  end

  # 幂等：追加过的内容再算一次仍是 merge，不会要求重复追加。
  def test_changelog_append_is_idempotent
    body = "#{SebasAgents::MergeQueue::CHANGELOG_MARKER}\n```\n- 其它条目 (#50)\n```\n"
    prs = [pr(number: 50, issue: 1, body: body)]
    content = "## [Unreleased]\n\n- 其它条目 (#50)\n"
    assert_equal "merge", plan([lease(issue: 1, pr: 50)], prs, changelog: content).step
    assert_equal "merge", plan([lease(issue: 1, pr: 50)], prs, changelog: content).step
  end

  # 文本相同的不同 PR 各写各的引用行，互不吞并。
  def test_same_text_from_other_pr_does_not_count
    body = "#{SebasAgents::MergeQueue::CHANGELOG_MARKER}\n```\n- 条目 (#50)\n```\n"
    prs = [pr(number: 50, issue: 1, body: body)]
    queue = plan([lease(issue: 1, pr: 50)], prs, changelog: "## [Unreleased]\n\n- 条目 (#49)\n")
    assert_equal "changelog", queue.step
  end

  # 没有 marker（旧路径：worker 自己写 CHANGELOG）→ 不要求队列追加。
  def test_pr_without_marker_needs_no_append
    prs = [pr(number: 50, issue: 1, body: "普通正文，无 marker")]
    queue = plan([lease(issue: 1, pr: 50)], prs, changelog: "## [Unreleased]\n")
    assert_equal "merge", queue.step
    assert_nil queue.entries.first.changelog_pending
  end

  # 声明了 marker 但条目为空：仍按 pending 处理，不静默放行。
  def test_empty_changelog_block_still_pending
    body = "#{SebasAgents::MergeQueue::CHANGELOG_MARKER}\n```\n```\n"
    prs = [pr(number: 50, issue: 1, body: body)]
    queue = plan([lease(issue: 1, pr: 50)], prs, changelog: "## [Unreleased]\n")
    assert_equal "changelog", queue.step
    assert_equal [], queue.entries.first.changelog_pending
  end

  # 读不到 CHANGELOG 时按未核验处理，不当作已写入。
  def test_unknown_changelog_is_not_treated_as_written
    body = "#{SebasAgents::MergeQueue::CHANGELOG_MARKER}\n```\n- 条目 (#50)\n```\n"
    prs = [pr(number: 50, issue: 1, body: body)]
    queue = plan([lease(issue: 1, pr: 50)], prs, changelog: nil)
    assert_equal "changelog", queue.step
    assert_includes queue.blocked_by, "未读到"
  end

  # --- 串行：队首按 issue 号稳定排序，一次只处理一张 ---

  def test_queue_is_serial_and_stable
    prs = [pr(number: 52, issue: 3), pr(number: 50, issue: 1), pr(number: 51, issue: 2)]
    leases = [lease(issue: 3, pr: 52), lease(issue: 1, pr: 50), lease(issue: 2, pr: 51)]
    queue = plan(leases, prs)
    assert_equal [1, 2, 3], queue.entries.map { |entry| entry.issue }
    assert_equal 1, queue.head
    # 与输入顺序无关：同样的集合再规划一次结果相同
    assert_equal queue.entries.map(&:issue), plan(leases.reverse, prs).entries.map(&:issue)
  end
end
