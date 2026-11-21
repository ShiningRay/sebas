# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "evidence_register"

class EvidenceRegisterTest < Minitest::Test
  ER = EvidenceRegister

  def block(**overrides)
    ER.evidence_block(
      issue_number: 42, pr_number: 99, merge_commit: "abc123",
      checks: "https://ci/1", untested: [], source_ref: "https://gh/c/1"
    ).merge(overrides.transform_keys(&:to_s))
  end

  # --- 幂等 ---

  def test_existing_evidence_is_detected
    body = "## 目标\nx\n\n## Evidence\n\n```json evidence\n#{JSON.generate(block)}\n```\n"
    refute_nil ER.existing_evidence(body)
  end

  def test_missing_evidence_is_nil
    assert_nil ER.existing_evidence("## 目标\nx\n")
  end

  def test_malformed_evidence_is_nil
    assert_nil ER.existing_evidence("```json evidence\n{not json}\n```")
  end

  # --- issue 关联解析 ---

  def test_closing_issue_parses_fixes
    assert_equal 42, ER.closing_issue({"body" => "Fixes #42"})
  end

  def test_closing_issue_parses_variants
    assert_equal 7, ER.closing_issue({"body" => "closes #7"})
    assert_equal 8, ER.closing_issue({"body" => "Resolved #8"})
  end

  def test_closing_issue_rejects_multiple
    assert_nil ER.closing_issue({"body" => "Fixes #1\nFixes #2"})
  end

  def test_closing_issue_rejects_none
    assert_nil ER.closing_issue({"body" => "no linkage here"})
  end

  # --- 正文回填 ---

  def test_upsert_appends_when_absent
    updated = ER.upsert_evidence_section("## 目标\n\nx\n", block)
    assert_includes updated, "## Evidence"
    assert_includes updated, "```json evidence"
    # 原有内容不能丢
    assert_includes updated, "## 目标"
  end

  def test_upsert_replaces_existing_section
    old = "## 目标\n\nx\n\n## Evidence\n\nOLD CONTENT\n\n## 验收\n\ny\n"
    updated = ER.upsert_evidence_section(old, block)
    refute_includes updated, "OLD CONTENT"
    assert_includes updated, "## 验收", "后续小节必须保留"
    assert_includes updated, "issue:42"
  end

  def test_upsert_is_stable_on_rerun
    once = ER.upsert_evidence_section("## 目标\n\nx\n", block)
    twice = ER.upsert_evidence_section(once, block)
    assert_equal once, twice
  end

  # --- 证据块形状必须与 Policy::Evidence 的契约一致 ---

  def test_block_matches_policy_contract
    b = block
    assert_equal 1, b["schema"]
    assert_equal "issue:42", b["subject"]
    assert_equal "accepted", b["status"]
    assert_equal "workflow", b["source"]
    assert_equal true, b["merged_into_main"]
    assert_equal [], b["untested"]
    assert_nil b["ready"]
    assert_nil b["gate_status"]
  end

  # 契约要求：登记的评论正文必须包含同一份 evidence 块，
  # 否则 Policy::Evidence.registration_matches? 会拒绝。
  def test_comment_body_carries_parseable_block
    b = block
    parsed = ER.existing_evidence(ER.render_comment(b))
    refute_nil parsed
    assert_equal b["subject"], parsed["subject"]
    assert_equal b["status"], parsed["status"]
    assert_equal b["source_ref"], parsed["source_ref"]
  end

  def test_untested_is_not_hardcoded_empty
    # 若将来加入真机验证要求，untested 必须能承载它们。
    b = ER.evidence_block(
      issue_number: 1, pr_number: 2, merge_commit: "x", checks: "u",
      untested: ["真机 round-trip"], source_ref: "r"
    )
    assert_equal ["真机 round-trip"], b["untested"]
  end

  # --- PR 解析 ---

  def test_resolve_pr_from_dispatch_input
    assert_equal 5, ER.resolve_pr({"EVENT_NAME" => "workflow_dispatch", "INPUT_PR" => "5"})
  end

  def test_resolve_pr_from_workflow_run
    assert_equal 6, ER.resolve_pr({"EVENT_NAME" => "workflow_run", "RUN_PR" => "6"})
  end

  def test_resolve_pr_rejects_null_run_pr
    assert_nil ER.resolve_pr({"EVENT_NAME" => "workflow_run", "RUN_PR" => "null"})
  end

  def test_resolve_pr_rejects_blank_dispatch
    assert_nil ER.resolve_pr({"EVENT_NAME" => "workflow_dispatch", "INPUT_PR" => ""})
  end

  # --- 失败回滚：评论发出后下游失败必须删评论 ---

  class FakeGh
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def call(path, method:, body: nil)
      @calls << [method, path]
      key = "#{method} #{path}"
      value = @responses[key]
      raise "gh api #{method} #{path} 失败" if value.nil? && method != "DELETE"

      value
    end
  end

  def run_with(fake, env)
    ER.runner = fake
    out = StringIO.new
    code = ER.run(env: env, out: out)
    [code, fake.calls, out.string]
  ensure
    ER.runner = nil
  end

  BASE_ENV = {
    "GITHUB_REPOSITORY" => "o/r",
    "EVENT_NAME" => "workflow_run",
    "RUN_PR" => "99",
    "RUN_URL" => "https://ci/1"
  }.freeze

  BASE_RESPONSES = {
    "GET repos/o/r/pulls/99" => {"merged_at" => "x", "body" => "Fixes #42", "merge_commit_sha" => "abc"},
    "GET repos/o/r/issues/42" => {"state" => "closed", "state_reason" => "completed", "body" => ""}
  }.freeze

  def test_rollback_deletes_comment_when_body_update_fails
    fake = FakeGh.new(BASE_RESPONSES.merge(
      "POST repos/o/r/issues/42/comments" => {"id" => 1, "html_url" => "u"},
      "PATCH repos/o/r/issues/comments/1" => {}
      # PATCH issues/42 故意缺失 → 失败
    ))
    code, calls, = run_with(fake, BASE_ENV)

    assert_equal 1, code, "失败必须 exit 1"
    assert_includes calls, ["DELETE", "repos/o/r/issues/comments/1"],
      "必须回滚删除刚发的评论，calls=#{calls.inspect}"
  end

  def test_no_writes_when_pr_not_merged
    fake = FakeGh.new("GET repos/o/r/pulls/99" => {"merged_at" => nil, "body" => "Fixes #42"})
    code, calls, out = run_with(fake, BASE_ENV)

    assert_equal 0, code
    assert_equal [["GET", "repos/o/r/pulls/99"]], calls
    assert_includes out, "未合并"
  end

  def test_idempotent_skip_does_not_write
    fake = FakeGh.new(BASE_RESPONSES.merge(
      "GET repos/o/r/issues/42" => {
        "state" => "closed", "state_reason" => "completed",
        "body" => "```json evidence\n{\"subject\":\"issue:42\"}\n```"
      }
    ))
    code, calls, out = run_with(fake, BASE_ENV)

    assert_equal 0, code
    assert(calls.none? { |m, _| m != "GET" }, "幂等跳过不得产生写入，calls=#{calls.inspect}")
    assert_includes out, "已有 Evidence"
  end
end
