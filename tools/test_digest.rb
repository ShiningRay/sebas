# frozen_string_literal: true

  # Proposal 置顶索引（digest）的纯逻辑回归。
  # 工具只做机械汇总：判定时间线可确定性提取；「已达成 / 待裁决」是语义判断，永不覆盖人工区。
require "minitest/autorun"
require "json"
require_relative "agents/lib/sebas_agents"

class DigestTest < Minitest::Test
  D = SebasAgents::Digest

  def comment(body, at: "2026-11-23T00:00:00Z", url: "https://github.com/o/r/issues/1#issuecomment-1", login: "ShiningRay", type: "User")
    {"body" => body, "created_at" => at, "html_url" => url, "user" => {"login" => login, "type" => type}}
  end

  def arch_comment(status, at: "2026-11-23T00:00:00Z", url: "https://github.com/o/r/issues/1#issuecomment-2")
    comment("<!-- status: #{status} -->\n<!-- arch: issue-arch -->\n研判正文", at: at, url: url)
  end

  def issue
    {"number" => 1, "title" => "上下文管理可插拔"}
  end

  def test_status_requires_first_line
    assert_equal "needs-design", D.status_of("<!-- status: needs-design -->\n<!-- arch: issue-arch -->\n正文")
  end

  # 摘要评论自己带着摘要标记；若被当成研判，每刷新一次摘要就会多算一轮。
  def test_status_ignores_digest_comment
    body = "#{D::MARKER}\n#{D::CIRCUIT_BREAKER}\n## 当前状态\n\n| 最新判定 | `needs-design` |"
    assert_nil D.status_of(body)
  end

  def test_build_emits_circuit_breaker
    body = D.build(issue, [])
    assert_includes body, D::CIRCUIT_BREAKER
  end

  def test_status_ignored_when_quoted_mid_body
    body = "正文引用\n<!-- status: needs-design -->\n"
    assert_nil D.status_of(body)
  end

  def test_status_rejects_unknown_shape
    assert_nil D.status_of("<!-- status: Needs Design -->")
  end

  def test_jarvis_requires_arch_marker
    assert D.jarvis?("<!-- arch: issue-arch -->\n正文")
    refute D.jarvis?("<!-- status: needs-design -->\n正文")
  end

  def test_machine_comment_detected_by_evidence_marker
    assert D.machine?(comment("<!-- evidence-register:bot -->\n\n## Evidence 登记"))
  end

  def test_machine_comment_detected_by_bot_author
    assert D.machine?(comment("正常文本", type: "Bot"))
  end

  def test_manual_comment_is_not_machine
    refute D.machine?(comment("用户补充说明"))
  end

  def test_build_counts_judgments_and_lists_timeline
    comments = [
      arch_comment("needs-design", at: "2026-11-23T00:00:00Z", url: "https://github.com/o/r/issues/1#issuecomment-2"),
      arch_comment("accepted-design", at: "2026-11-25T00:00:00Z", url: "https://github.com/o/r/issues/1#issuecomment-3"),
      comment("用户补充")
    ]
    body = D.build(issue, comments)
    assert_includes body, "| 研判次数 | 2 |"
    assert_includes body, "| 人工评论 | 1 条 |"
    assert_includes body, "`accepted-design`"
    assert_includes body, "#issuecomment-3"
  end

  def test_build_marks_latest_status
    comments = [
      arch_comment("needs-design", at: "2026-11-23T00:00:00Z"),
      arch_comment("accepted-design", at: "2026-11-25T00:00:00Z", url: "https://github.com/o/r/issues/1#issuecomment-9")
    ]
    body = D.build(issue, comments)
    assert_includes body, "| 最新判定 | `accepted-design` |"
    assert_includes body, "| 最近研判 | 2026-11-25 |"
  end

  def test_build_without_judgment_says_so
    body = D.build(issue, [comment("用户补充")])
    assert_includes body, "尚无 Triager 研判评论"
  end

  # 人工区一旦存在，重建时必须原样保留 —— 工具的机械刷新不能吃掉人的结论。
  def test_build_preserves_manual_section
    existing = "#{D::MARKER}\n## 旧的机械区\n\n#{D::MANUAL_MARKER}\n\n### 已达成\n\n- 契约走文档\n\n### 待裁决\n\n- TTL 默认值\n"
    body = D.build(issue, [arch_comment("needs-design")], existing_body: existing)
    assert_includes body, "### 已达成\n\n- 契约走文档"
    assert_includes body, "### 待裁决\n\n- TTL 默认值"
    refute_includes body, "旧的机械区"
  end

  def test_build_without_manual_section_seeds_placeholders
    body = D.build(issue, [arch_comment("needs-design")])
    assert_includes body, "### 已达成\n\n- （待填）"
    assert_includes body, "### 待裁决\n\n- （待填）"
  end

  def test_existing_finds_digest_comment
    digest = comment("#{D::MARKER}\n旧内容")
    assert_equal digest, D.existing([comment("普通"), digest])
  end

# 普通评论引用标记文本不算摘要：否则会覆盖别人的讨论。
def test_existing_requires_marker_on_own_line
  quoted = comment("我在讨论里提到 #{D::MARKER} 这个标记")
  refute(D.existing([quoted]), "标记内嵌在正文中不应被认作摘要")
end

def test_existing_rejects_duplicates
  a = comment("#{D::MARKER}\n第一条")
  b = comment("#{D::MARKER}\n第二条")
  err = assert_raises(SebasAgents::InvalidPlan) { D.existing([a, b]) }
  assert_includes err.message, "无法判定更新目标"
end

  def test_existing_nil_when_absent
    assert_nil D.existing([comment("普通")])
  end

  def test_build_escapes_pipe_in_title
    body = D.build({"number" => 1, "title" => "A | B"}, [])
    assert_includes body, "#1 A  B"
  end
end
