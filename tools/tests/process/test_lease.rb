# frozen_string_literal: true

# Lease 凭据与 Scope 预算的纯函数契约（M4x-Parallel-WP2，#220）。
#
# 租约的唯一性判定是 fail-closed 的：多条 active 租约、白名单外的作者、
# 损坏的凭据体都必须拒绝，不能挑一条「看起来对」的用。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class LeaseTest < Minitest::Test
  WHITELIST = ["ShiningRay"].freeze

  def lease_comment(id: 900, login: "ShiningRay", lease_id: "lease-1", state: "active",
                    issue: 1, branch: "feat/1", base_sha: "abc123")
    body = SebasAgents::Lease.comment_body(
      lease_id: lease_id, issue: issue, branch: branch, base_sha: base_sha,
      coordinator_id: "coord-a", host: "host-a", claimed_at: "2026-11-27T00:00:00Z", state: state
    )
    {"id" => id, "user" => {"login" => login}, "body" => body}
  end

  def test_comment_body_contains_marker_and_closed_field_set
    body = lease_comment["body"]
    assert_includes body, SebasAgents::Lease::MARKER
    credential = JSON.parse(body.split("```json sebas-lease\n").last.split("\n```").first)
    assert_equal %w[lease_id issue branch base_sha coordinator_id host state claimed_at].sort,
                 credential.keys.sort
    assert_equal "active", credential["state"]
  end

  def test_uniqueness_single_active_lease_is_returned
    credential = SebasAgents::Lease.active_lease([lease_comment], author_whitelist: WHITELIST)
    assert_equal "lease-1", credential["lease_id"]
    assert_equal "feat/1", credential["branch"]
  end

  def test_multiple_active_leases_fail_closed
    comments = [lease_comment(id: 900), lease_comment(id: 901, lease_id: "lease-2")]
    error = assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::Lease.active_lease(comments, author_whitelist: WHITELIST)
    end
    assert_includes error.message, "2 份有效租约"
  end

  def test_released_lease_does_not_count_as_active
    comments = [lease_comment(id: 900, state: "released"), lease_comment(id: 901, lease_id: "lease-2", state: "released")]
    assert_nil SebasAgents::Lease.active_lease(comments, author_whitelist: WHITELIST)
  end

  def test_author_outside_whitelist_fail_closed
    error = assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::Lease.active_lease([lease_comment(login: "nobody")], author_whitelist: WHITELIST)
    end
    assert_includes error.message, "coordinators 白名单"
  end

  def test_orphan_label_detection
    # 有标签、无有效凭据 → invalid_plan（F7）
    error = assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::Lease.assert_no_orphan_label(label_present: true, active_lease: nil, issue_number: 1)
    end
    assert_includes error.message, "无有效租约凭据"
    # 有标签且有凭据 → 通过
    SebasAgents::Lease.assert_no_orphan_label(
      label_present: true, active_lease: {"lease_id" => "lease-1"}, issue_number: 1)
    # 无标签 → 不判定
    SebasAgents::Lease.assert_no_orphan_label(label_present: false, active_lease: nil, issue_number: 1)
  end

  def test_find_by_lease_id_reuses_existing_comment_without_repost
    comments = [lease_comment(id: 900), lease_comment(id: 901, lease_id: "lease-2")]
    found = SebasAgents::Lease.find_by_lease_id(comments, "lease-1", author_whitelist: WHITELIST)
    assert_equal 900, found[0]
    assert_equal "lease-1", found[1]["lease_id"]
    assert_nil SebasAgents::Lease.find_by_lease_id(comments, "missing", author_whitelist: WHITELIST)
  end

  def test_malformed_lease_body_fail_closed
    malformed = {"id" => 902, "user" => {"login" => "ShiningRay"},
                 "body" => "#{SebasAgents::Lease::MARKER}\n不是凭据\n"}
    error = assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::Lease.active_lease([malformed], author_whitelist: WHITELIST)
    end
    assert_includes error.message, "sebas-lease"
  end

end
class ScopeTest < Minitest::Test
  def normalize(values)
    SebasAgents::Policy::Scope.normalize(values, issue_number: 1)
  end

  def test_normalize_appends_trailing_slash_and_keeps_order
    assert_equal ["src/store/", "spec/store/", "docs/"], normalize(["src/store", "spec/store/", "docs/"])
  end

  def test_normalize_rejects_illegal_values
    assert_raises(SebasAgents::InvalidPlan) { normalize([]) }
    assert_raises(SebasAgents::InvalidPlan) { normalize([1]) }
    assert_raises(SebasAgents::InvalidPlan) { normalize(["../secret"]) }
    assert_raises(SebasAgents::InvalidPlan) { normalize(["/abs"]) }
  end

  def test_conflict_by_prefix_containment
    conflict = SebasAgents::Policy::Scope
    assert conflict.conflict?(["src/"], ["src/bus/"])       # 前缀互相包含
    assert conflict.conflict?(["src/bus/"], ["src/bus/x.cr/"])
    refute conflict.conflict?(["src/bus/"], ["src/keys/"])  # 兄弟目录不冲突
    refute conflict.conflict?(nil, ["src/"])                # 未声明不参与
    refute conflict.conflict?(["docs/"], nil)
  end

  def test_filter_candidates_marks_conflicting_and_missing_scope
    candidates = [
      make_candidate(1, ["docs/"]),
      make_candidate(2, ["src/"]),
      make_candidate(3, nil)
    ]
    leases = [{issue: 9, scope: ["docs/proposals/"]}]
    ready, excluded = SebasAgents::Policy::Scope.filter_candidates(candidates, leases)
    # 容量 >1 语义：与在途租约重叠 → 排除；缺 scope → 独占语义，同样排除
    assert_equal [2], ready.map(&:number)
    assert_includes excluded.map { |row| row[:issue] }, 1
    assert_includes excluded.map { |row| row[:issue] }, 3
  end

  def make_candidate(number, scope)
    require "ostruct"
    automation = {
      "schema" => 1, "kind" => "work_package", "order" => [4, 1],
      "depends_on" => [], "external" => []
    }
    automation["scope"] = scope unless scope.nil?
    OpenStruct.new(number: number, automation: automation)
  end

end
