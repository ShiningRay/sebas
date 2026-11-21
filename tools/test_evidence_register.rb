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

  # --- 幂等判定（区分有效 / 非法 / 缺失）---

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

  # --- 证据块契约 ---

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

  # --- untested 唯一来源：卡面「未实测」小节 ---

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

  # --- PR 解析 ---

  def test_resolve_pr_from_dispatch_input
    assert_equal 5, ER.resolve_pr({"EVENT_NAME" => "workflow_dispatch", "INPUT_PR" => "5"})
  end

  def test_resolve_pr_rejects_noncanonical_dispatch_input
    # 099 与 99 会落到不同并发组，必须拒绝非规范写法。
    assert_nil ER.resolve_pr({"EVENT_NAME" => "workflow_dispatch", "INPUT_PR" => "099"})
  end

  def test_resolve_pr_from_workflow_run_pr
    assert_equal 6, ER.resolve_pr({"EVENT_NAME" => "workflow_run", "RUN_PR" => "6"})
  end

  def test_resolve_pr_falls_back_to_head_sha
    ER.runner = lambda do |path, method: "GET", body: nil|
      assert_equal "repos/o/r/commits/abc/pulls", path
      [{"number" => 9, "merged_at" => "x"}]
    end
    number = ER.resolve_pr(
      "EVENT_NAME" => "workflow_run", "RUN_PR" => "null",
      "RUN_HEAD_SHA" => "abc", "GITHUB_REPOSITORY" => "o/r"
    )
    assert_equal 9, number, "push 事件必须用 head_sha 反查已合并 PR"
  ensure
    ER.runner = nil
  end

  def test_resolve_pr_fallback_ignores_unmerged_candidates
    ER.runner = ->(_path, method: "GET", body: nil) { [{"number" => 9, "merged_at" => nil}] }
    assert_nil ER.resolve_pr(
      "EVENT_NAME" => "workflow_run", "RUN_PR" => "null",
      "RUN_HEAD_SHA" => "abc", "GITHUB_REPOSITORY" => "o/r"
    )
  ensure
    ER.runner = nil
  end

  def test_resolve_pr_returns_nil_without_any_signal
    assert_nil ER.resolve_pr({"EVENT_NAME" => "workflow_run", "RUN_PR" => "null", "RUN_HEAD_SHA" => ""})
  end

  # --- main 祖先校验 ---

  def test_merged_into_main_false_when_base_is_not_main
    # git_runner 返回 true 也不能放行：base_ref 不是 main 时应在调用 git 前就拒绝。
    ER.git_runner = ->(*args) { raise "不应调用 git：#{args.inspect}" }
    assert_equal false, ER.merged_into_main?("abc", base_ref: "release/0.2", out: StringIO.new)
  ensure
    ER.git_runner = nil
  end

  # base_ref 非 main 时必须短路，不能依赖 git 查询的偶然结果。
  def test_base_ref_not_main_short_circuits_before_git
    called = []
    ER.git_runner = ->(*args) { called << args; true }
    ER.merged_into_main?("abc", base_ref: "release/0.2", out: StringIO.new)
    assert_empty called, "已知不在 main 分支时不应再查 git"
  ensure
    ER.git_runner = nil
  end

  def test_merged_into_main_consults_git
    ER.git_runner = ->(*_args) { true }
    assert_equal true, ER.merged_into_main?("abc", base_ref: "main", out: StringIO.new)
  ensure
    ER.git_runner = nil
  end

  def test_merged_into_main_rejects_when_git_says_no
    ER.git_runner = ->(*_args) { false }
    assert_equal false, ER.merged_into_main?("abc", base_ref: "main", out: StringIO.new)
  ensure
    ER.git_runner = nil
  end

  def test_merged_into_main_rejects_empty_sha
    assert_equal false, ER.merged_into_main?("", out: StringIO.new)
  end

  # --- 手动触发的 CI 校验 ---

  def test_checks_url_uses_run_url_when_present
    assert_equal "https://ci/1", ER.resolve_checks_url({"RUN_URL" => "https://ci/1"}, 1, out: StringIO.new)
  end

  # 触发 CI 的提交与合并提交不一致时，不能拿该 CI 的 URL 当合并结果证据。
  def test_checks_url_fails_when_run_sha_differs_from_merge_commit
    ER.runner = lambda do |path, method: "GET", body: nil|
      raise "unexpected #{path}" unless path =~ %r{/pulls/}

      {"merge_commit_sha" => "merge111"}
    end
    out = StringIO.new
    result = ER.resolve_checks_url(
      {"GITHUB_REPOSITORY" => "o/r", "RUN_URL" => "https://ci/pr-head",
       "RUN_HEAD_SHA" => "prhead222"},
      1, out: out
    )
    assert_equal :failed, result
    assert_includes out.string, "不一致"
  ensure
    ER.runner = nil
  end

  def test_checks_url_accepts_when_run_sha_matches_merge_commit
    ER.runner = ->(_path, method: "GET", body: nil) { {"merge_commit_sha" => "same"} }
    url = ER.resolve_checks_url(
      {"GITHUB_REPOSITORY" => "o/r", "RUN_URL" => "https://ci/x", "RUN_HEAD_SHA" => "same"},
      1, out: StringIO.new
    )
    assert_equal "https://ci/x", url
  ensure
    ER.runner = nil
  end

  def test_checks_url_fails_without_successful_run
    ER.runner = lambda do |path, method: "GET", body: nil|
      case path
      when %r{/pulls/} then {"merge_commit_sha" => "abc"}
      when %r{/actions/runs} then {"workflow_runs" => [{"name" => "CI", "conclusion" => "failure"}]}
      else raise "unexpected #{path}"
      end
    end
    out = StringIO.new
    assert_equal :failed, ER.resolve_checks_url({"GITHUB_REPOSITORY" => "o/r", "RUN_URL" => ""}, 1, out: out)
    assert_includes out.string, "拒绝登记"
  ensure
    ER.runner = nil
  end

  # --- 失败回滚 ---

  class FakeGh
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def call(path, method:, body: nil)
      @calls << [method, path]
      key = "#{method} #{path}"
      value = @responses.respond_to?(:call) ? @responses.call(key, @calls) : @responses[key]
      raise "gh api #{method} #{path} 失败" if value.nil? && method != "DELETE"

      value
    end
  end

  BASE_ENV = {
    "GITHUB_REPOSITORY" => "o/r",
    "EVENT_NAME" => "workflow_run",
    "RUN_PR" => "99",
    "RUN_URL" => "https://ci/1"
  }.freeze

  BASE_RESPONSES = {
    "GET repos/o/r/pulls/99" => {
      "merged_at" => "x", "body" => "Fixes #42", "merge_commit_sha" => "abc",
      "base" => {"ref" => "main"}
    },
    "GET repos/o/r/issues/42" => {"state" => "closed", "state_reason" => "completed", "body" => ""}
  }.freeze

  def run_with(fake, env, git_ok: true)
    ER.runner = fake
    ER.git_runner = ->(*_args) { git_ok }
    out = StringIO.new
    code = ER.run(env: env, out: out)
    [code, fake.calls, out.string]
  ensure
    ER.runner = nil
    ER.git_runner = nil
  end

  def test_rollback_deletes_comment_when_body_not_yet_written
    fake = FakeGh.new(BASE_RESPONSES.merge(
      "POST repos/o/r/issues/42/comments" => {"id" => 1, "html_url" => "u"},
      "PATCH repos/o/r/issues/comments/1" => {},
      "GET repos/o/r/issues/42" => {"state" => "closed", "state_reason" => "completed", "body" => ""}
      # PATCH issues/42 故意缺失 → 失败
    ))
    code, calls, = run_with(fake, BASE_ENV)

    assert_equal 1, code
    assert_includes calls, ["DELETE", "repos/o/r/issues/comments/1"],
      "正文未引用时必须删除评论，calls=#{calls.inspect}"
  end

  def test_no_delete_when_body_already_references_comment
    # 模拟 PATCH 报错但服务端已写入：正文已含该 URL，不能删评论。
    fake = FakeGh.new(
      "GET repos/o/r/pulls/99" => BASE_RESPONSES["GET repos/o/r/pulls/99"],
      "GET repos/o/r/issues/42" => {
        "state" => "closed", "state_reason" => "completed",
        "body" => "see https://github.com/o/r/issues/42#issuecomment-1"
      },
      "POST repos/o/r/issues/42/comments" => {"id" => 1, "html_url" => "https://github.com/o/r/issues/42#issuecomment-1"},
      "PATCH repos/o/r/issues/comments/1" => {}
      # PATCH issues/42 缺失 → 触发回滚路径
    )
    code, calls, = run_with(fake, BASE_ENV)

    assert_equal 1, code
    refute_includes calls, ["DELETE", "repos/o/r/issues/comments/1"],
      "正文已引用评论时不得删除，calls=#{calls.inspect}"
  end

  def test_skips_when_merge_commit_not_in_main
    fake = FakeGh.new("GET repos/o/r/pulls/99" => BASE_RESPONSES["GET repos/o/r/pulls/99"])
    code, calls, out = run_with(fake, BASE_ENV, git_ok: false)

    assert_equal 0, code
    assert_equal [["GET", "repos/o/r/pulls/99"]], calls, "不得产生写入"
    assert_includes out, "不在 main 上"
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
        "body" => "```json evidence\n#{JSON.generate(ER.evidence_block(
          issue_number: 42, pr_number: 99, merge_commit: "abc",
          checks: "c", untested: [], source_ref: "r"
        ))}\n```"
      }
    ))
    code, calls, out = run_with(fake, BASE_ENV)

    assert_equal 0, code
    assert(calls.none? { |m, _| m != "GET" }, "幂等跳过不得产生写入，calls=#{calls.inspect}")
    assert_includes out, "已有有效 Evidence"
  end

  def test_invalid_existing_evidence_exits_nonzero
    fake = FakeGh.new(BASE_RESPONSES.merge(
      "GET repos/o/r/issues/42" => {
        "state" => "closed", "state_reason" => "completed",
        "body" => "```json evidence\n{\"subject\":\"issue:42\"}\n```"
      }
    ))
    code, calls, = run_with(fake, BASE_ENV)

    assert_equal 1, code, "结构非法的既有证据必须 fail-closed"
    assert(calls.none? { |m, _| m != "GET" })
  end

  def test_malformed_existing_block_exits_nonzero_without_writes
    fake = FakeGh.new(BASE_RESPONSES.merge(
      "GET repos/o/r/issues/42" => {
        "state" => "closed", "state_reason" => "completed",
        "body" => "```json evidence\n{not json}\n```"
      }
    ))
    code, calls, = run_with(fake, BASE_ENV)

    assert_equal 1, code, "损坏的块不能被当成缺失而追加第二份"
    assert(calls.none? { |m, _| m != "GET" }, "不得写入，calls=#{calls.inspect}")
  end

  # 首读到写入之间「未实测」小节被改动时，登记会漏掉新增项，必须中止。
  def test_aborts_when_untested_declarations_change_mid_flight
    issue_reads = 0
    fake = FakeGh.new(lambda do |key, _calls|
      case key
      when "GET repos/o/r/pulls/99" then BASE_RESPONSES["GET repos/o/r/pulls/99"]
      when "GET repos/o/r/issues/42"
        issue_reads += 1
        # 两次读取都带「未实测」小节，但内容不同——这才是真正的「期间被改」。
        body = if issue_reads == 1
          "## 目标\nx\n\n## 未实测\n\n- 原有的要求\n"
        else
          "## 目标\nx\n\n## 未实测\n\n- 原有的要求\n- 期间新增的要求\n"
        end
        {"state" => "closed", "state_reason" => "completed", "body" => body}
      when "POST repos/o/r/issues/42/comments" then {"id" => 1, "html_url" => "https://gh/c/1"}
      when "PATCH repos/o/r/issues/comments/1" then {}
      end
    end)

    code, calls, = run_with(fake, BASE_ENV)
    assert_equal 1, code, "声明变化必须中止登记"
    # 未写入正文：PATCH issues/42 不应出现。
    refute(calls.any? { |m, p| m == "PATCH" && p.end_with?("/issues/42") },
      "不得写入正文，calls=#{calls.inspect}")
  end

  def test_does_not_abort_when_declarations_unchanged
    fake = FakeGh.new(BASE_RESPONSES.merge(
      "GET repos/o/r/issues/42" => {
        "state" => "closed", "state_reason" => "completed",
        "body" => "## 目标\nx\n\n## 未实测\n\n- 稳定的要求\n"
      },
      "POST repos/o/r/issues/42/comments" => {"id" => 1, "html_url" => "https://gh/c/1"},
      "PATCH repos/o/r/issues/comments/1" => {},
      "PATCH repos/o/r/issues/42" => {}
    ))
    code, = run_with(fake, BASE_ENV)
    assert_equal 0, code, "声明未变时应正常登记"
  end
end
