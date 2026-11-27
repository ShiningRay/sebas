# frozen_string_literal: true

# 合并队列与逐租约路由的故障注入（M4x-Parallel-WP3，#221；续篇 F8、F10、F12）。
#
# 只覆盖**纯函数可判定**的部分：这些判定错了会让「没核验的提交被合并」或
# 「错的分支被当成租约」，属不可撤销的错误，比性能问题严重得多。
# 需要真实远端时序的场景（F11、F13、F14、F15）在仓库内没有可注入的接口，
# 归入未实测，不在本文件伪造。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class QueueFaultsTest < Minitest::Test
  include SnapshotHelpers

  def pr(number: 50, issue: 1, head: "sha50", base: "main", state: "OPEN",
    merge_state: "CLEAN", checks: [], threads: [], merged: false, body: nil)
    {
      "number" => number, "head_ref_name" => "feat/#{issue}", "base_ref_name" => base,
      "head_sha" => head, "state" => state, "merged" => merged,
      "merge_state_status" => merge_state, "checks" => checks,
      "closing_issues" => [issue], "review_threads" => threads, "body" => body
    }
  end

  def snap(prs)
    SebasAgents::Model::Snapshot.from_hash(snapshot(issues: [], pull_requests: prs))
  end

  def lease(issue: 1, pr_number: 50, action: "merge_ready")
    SebasAgents::Policy::Selection::LeaseAction.new(
      issue: issue, action: action, reason: "t", pr: pr_number, owned: true)
  end

  # F8：base_sha 过期 —— 合并队列的规划必须把 head 记进 entry，
  # 否则执行侧只能「按当前 head 合」，等于放弃绑定。
  def test_queue_records_head_for_binding
    queue = SebasAgents::MergeQueue.plan([lease], snap([pr(head: "abc123")]))
    assert_equal "abc123", queue.entries.first.head_sha,
      "队首必须携带规划时的 head，执行侧据此绑定 --match-head-commit"
  end

  # F10：目标分支被改写 —— 非 main 的 base 必须在 verify_pre 就挡住。
  def test_base_change_blocks_before_merge
    queue = SebasAgents::MergeQueue.plan([lease], snap([pr(base: "hotfix/0.2.1")]))
    assert_equal "verify_pre", queue.step
    assert_includes queue.blocked_by, "只允许 main"
  end

  # F10 变体：head 变了但 base 没变 —— 规划与执行之间重读会发现，执行侧拒绝。
  # 纯函数层只能锁住「entry 里带的 head 是规划时的值」，重读逻辑由 CLI 承担。
  def test_queue_entry_head_matches_snapshot_not_later_state
    queue = SebasAgents::MergeQueue.plan([lease], snap([pr(head: "sha-old")]))
    assert_equal "sha-old", queue.entries.first.head_sha
  end

  # F12：租约已释放 / PR 已合并 —— 队列不能把已合并的 PR 当「待合并」。
  def test_merged_pr_is_not_planned_for_merge
    queue = SebasAgents::MergeQueue.plan(
      [lease], snap([pr(state: "MERGED", merged: true)]))
    refute_equal "merge", queue.step,
      "已合并的 PR 不能再规划一次合并，否则执行侧会对着已关闭的 PR 发 merge"
    assert_equal "release", queue.step
  end

  # 队列空时不能报错，也不能凭空产生队首。
  def test_empty_queue_with_no_leases
    queue = SebasAgents::MergeQueue.plan([], snap([]))
    assert queue.empty?
    assert_nil queue.step
  end

  # 只有 merge_ready 进队：waiting 的租约不该被当成可合并。
  def test_waiting_lease_not_queued
    queue = SebasAgents::MergeQueue.plan([lease(action: "wait")], snap([pr]))
    assert queue.empty?
  end

  # 归属不符的租约即使检查全绿也不得给出可执行动作（续篇 §9 必测场景 5）。
  def test_foreign_lease_never_owned
    data = snapshot(
      issues: [issue(1, body: automation(scope: ["src/"]), status: "In progress")],
      pull_requests: [pr(head: "s", base: "main")],
      capacity: 2
    )
    # 无本地记录 → owned=false；即使算得出 merge_ready，也不该被当成本机可执行的租约
    view = SebasAgents::Policy::Selection.plan(SebasAgents::Model::Snapshot.from_hash(data))
    assert_empty view.leases.select(&:owned), "无本地记录的租约不属于本机"
  end
end
