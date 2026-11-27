# frozen_string_literal: true

# Evidence 块的读写契约：幂等判定（有效 / 非法 / 缺失）、issue 关联解析、
# 正文回填、块字段契约与 untested 的唯一来源。

require_relative "../support/boot"
require_relative "../../evidence_register"

class EvidenceBlockTest < Minitest::Test
  ER = EvidenceRegister

  def block(**overrides)
    ER.evidence_block(
      issue_number: 42, pr_number: 99, merge_commit: "abc123",
      checks: "https://ci/1", untested: [], source_ref: "https://gh/c/1"
    ).merge(overrides.transform_keys(&:to_s))
  end

  def test_existing_valid_evidence
    body = "## 目标\nx\n\n## Evidence\n\n```json evidence\n#{JSON.generate(block)}\n```\n"
    assert_equal :valid, ER.existing_evidence(body, subject: "issue:42")
  end

  def test_existing_invalid_evidence_is_reported_not_skipped
    # 只有 subject，缺 status/source/source_ref —— 策略层会拒绝这种块。
    body = "```json evidence\n{\"subject\":\"issue:42\"}\n```"
    assert_equal :invalid, ER.existing_evidence(body, subject: "issue:42")
  end

  # 每条必填字段缺失都必须判 invalid，不能只看 schema 与 subject。
  def test_existing_evidence_missing_each_required_field_is_invalid
    {status: "", source: "", source_ref: ""}.each do |field, blank|
      b = block.merge(field.to_s => blank)
      body = "```json evidence\n#{JSON.generate(b)}\n```"
      assert_equal :invalid, ER.existing_evidence(body, subject: "issue:42"),
        "缺 #{field} 时必须判 invalid"
    end
  end

  def test_existing_evidence_with_wrong_schema_is_invalid
    b = block.merge("schema" => 2)
    body = "```json evidence\n#{JSON.generate(b)}\n```"
    assert_equal :invalid, ER.existing_evidence(body, subject: "issue:42")
  end

  def test_existing_evidence_with_wrong_subject_is_invalid
    body = "```json evidence\n#{JSON.generate(block)}\n```"
    assert_equal :invalid, ER.existing_evidence(body, subject: "issue:99")
  end

  def test_missing_evidence_is_absent
    assert_equal :absent, ER.existing_evidence("## 目标\nx\n", subject: "issue:42")
  end

  def test_malformed_evidence_is_invalid_not_absent
    # 有 fence 但 JSON 损坏：不能当成「没有证据」放行，否则会追加第二个块。
    assert_equal :invalid, ER.existing_evidence("```json evidence\n{not json}\n```", subject: "issue:42")
  end

  def test_fence_without_block_is_invalid
    assert_equal :invalid, ER.existing_evidence("```json evidence\nno json here\n```", subject: "issue:42")
  end

  # 正文里只是提到这个词，不是真的代码围栏——不能判成损坏块。
  def test_prose_mention_is_absent_not_invalid
    body = "## 目标\n\nDocument the json evidence format for contributors.\n"
    assert_equal :absent, ER.existing_evidence(body, subject: "issue:42")
  end

  def test_inline_mention_with_backtick_is_absent
    body = "## 目标\n\n参见 `json evidence` 的写法说明。\n"
    assert_equal :absent, ER.existing_evidence(body, subject: "issue:42")
  end

  # CR-only 换行：必须与下游 JsonBlock.normalize 同口径识别，
  # 否则会把已有合法块当缺失，追加后形成重复块且无法自愈。
  def test_cr_only_line_endings_are_detected
    body = "## 目标\r\r## Evidence\r\r```json evidence\r#{JSON.generate(block)}\r```\r"
    assert_equal :valid, ER.existing_evidence(body, subject: "issue:42")
  end

  def test_crlf_line_endings_are_detected
    body = "## 目标\r\n\r\n```json evidence\r\n#{JSON.generate(block)}\r\n```\r\n"
    assert_equal :valid, ER.existing_evidence(body, subject: "issue:42")
  end

  # 多个块：下游 JsonBlock.one 会拒绝，这里必须同口径判 invalid 而非取第一块跳过。
  def test_duplicate_blocks_are_invalid
    one_block = "```json evidence\n#{JSON.generate(block)}\n```"
    body = "## 目标\nx\n\n#{one_block}\n\n#{one_block}\n"
    assert_equal :invalid, ER.existing_evidence(body, subject: "issue:42")
  end

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

  def test_upsert_appends_when_absent
    updated = ER.upsert_evidence_section("## 目标\n\nx\n", block)
    assert_includes updated, "## Evidence"
    assert_includes updated, "```json evidence"
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

  def test_upsert_preserves_other_sections_verbatim
    original = "## 目标\n\n重要内容\n\n## 验收\n\n关键标准\n"
    updated = ER.upsert_evidence_section(original, block)
    assert_includes updated, "重要内容"
    assert_includes updated, "关键标准"
  end

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

  def test_comment_body_carries_parseable_block
    b = block
    parsed = ER.parse_block(ER.render_comment(b))
    refute_nil parsed
    assert_equal b["subject"], parsed["subject"]
    assert_equal b["status"], parsed["status"]
    assert_equal b["source_ref"], parsed["source_ref"]
  end

  def test_declared_untested_reads_section
    body = "## 目标\nx\n\n## 未实测\n\n- M7 真机 round-trip\n- 第二项\n\n## 验收\ny\n"
    assert_equal ["M7 真机 round-trip", "第二项"], ER.declared_untested(body)
  end

  def test_declared_untested_absent_section_is_empty
    assert_equal [], ER.declared_untested("## 目标\nx\n")
  end

  def test_declared_untested_explicit_none_is_empty
    assert_equal [], ER.declared_untested("## 未实测\n\n无\n")
  end

  def test_comment_id_from_parses_url
    require_relative "../../evidence_register_twophase"
    assert_equal 7, EvidenceRegister::TwoPhase.comment_id_from("https://github.com/o/r/issues/42#issuecomment-7")
    assert_nil EvidenceRegister::TwoPhase.comment_id_from("https://gh/c/1")
  end
end
