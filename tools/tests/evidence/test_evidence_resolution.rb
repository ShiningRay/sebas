# frozen_string_literal: true

# Evidence 登记的前置解析：PR 编号来源、main 祖先校验、手动触发 CI 的采纳条件。

require_relative "../support/boot"
require_relative "../../evidence_register"

class EvidenceResolutionTest < Minitest::Test
  ER = EvidenceRegister

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
end
