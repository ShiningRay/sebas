# frozen_string_literal: true

# accept-proposal 的离线测试：只测纯函数与失败前置条件，不打 GitHub。

require_relative "../support/boot"

# accept-proposal 无 .rb 扩展名，require_relative 不认；用绝对路径 load。
load File.expand_path("../../accept-proposal", __dir__)

class AcceptProposalTest < Minitest::Test
  def test_verdict_comment_has_marker_on_own_line_and_reason
    assert_equal RepoPaths::ROOT, REPO_ROOT
    body = AcceptProposal.verdict_comment("方向成立，排期另议。\n")
    assert body.start_with?("<!-- proposal-verdict: accepted-design -->\n")
    assert_includes body, "方向成立，排期另议。"
    refute_includes body, "方向成立，排期另议。\n\n\n"
  end

  def test_with_decision_marker_appends_once_and_is_idempotent
    url = "https://github.com/o/r/issues/8#issuecomment-1"
    original = "### Problem\n\n详情\n"
    with_marker = AcceptProposal.with_decision_marker(original, url)
    assert_includes with_marker, "<!-- proposal-decision: #{url} -->"
    assert_includes with_marker, "### Problem"
    assert_equal with_marker, AcceptProposal.with_decision_marker(with_marker, url)
  end

  def test_with_decision_marker_handles_nil_body
    url = "https://github.com/o/r/issues/8#issuecomment-1"
    result = AcceptProposal.with_decision_marker(nil, url)
    assert result.start_with?("<!-- proposal-decision: #{url} -->")
  end

  def test_read_maintainers_parses_top_level_section
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".github"))
      File.write(File.join(dir, ".github", "agents.yml"), <<~YML)
        maintainers:
          - ShiningRay
          - another-human
        trusted_bots:
          - github-actions[bot]
      YML
      assert_equal ["ShiningRay", "another-human"], AcceptProposal.read_maintainers(root: dir)
    end
  end

  def test_read_maintainers_rejects_missing_file
    Dir.mktmpdir do |dir|
      err = assert_raises(AcceptProposal::Failure) { AcceptProposal.read_maintainers(root: dir) }
      assert_includes err.message, "agents.yml"
    end
  end

  def test_preflight_rejects_closed_issue
    issue = {"labels" => [{"name" => "proposal"}], "state" => "closed"}
    err = assert_raises(AcceptProposal::Failure) do
      AcceptProposal.preflight!(issue, 8, repo: "o/r", login: "ShiningRay", maintainers: ["ShiningRay"])
    end
    assert_includes err.message, "已关闭"
  end

  def test_preflight_rejects_non_maintainer
    issue = {"labels" => [{"name" => "proposal"}], "state" => "open"}
    err = assert_raises(AcceptProposal::Failure) do
      AcceptProposal.preflight!(issue, 8, repo: "o/r", login: "someone", maintainers: ["ShiningRay"])
    end
    assert_includes err.message, "maintainers"
  end

  def test_preflight_rejects_missing_proposal_label
    issue = {"labels" => [{"name" => "enhancement"}], "state" => "open"}
    err = assert_raises(AcceptProposal::Failure) do
      AcceptProposal.preflight!(issue, 8, repo: "o/r", login: "ShiningRay", maintainers: ["ShiningRay"])
    end
    assert_includes err.message, "proposal"
  end

  def test_preflight_allows_already_accepted
    issue = {"labels" => [{"name" => "proposal"}, {"name" => "proposal:accepted-design"}], "state" => "open"}
    # 已接受不再是错误：重试时走幂等补齐路径。
    AcceptProposal.preflight!(issue, 8, repo: "o/r", login: "ShiningRay", maintainers: ["ShiningRay"])
  end

  def test_preflight_rejects_work_package_card_with_proposal_label
    issue = {
      "labels" => [{"name" => "proposal"}],
      "state" => "open",
      "body" => "```json automation\n{\"schema\":1,\"kind\":\"work_package\"}\n```\n"
    }
    err = assert_raises(AcceptProposal::Failure) do
      AcceptProposal.preflight!(issue, 8, repo: "o/r", login: "ShiningRay", maintainers: ["ShiningRay"])
    end
    assert_includes err.message, "Automation"
  end

  def test_registered_decision_urls_extracts_marker
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    body = AcceptProposal.with_decision_marker("正文", url)
    assert_equal [url], AcceptProposal.registered_decision_urls(body)
  end

  def test_status_comment_body_has_markers_and_url
    evidence = sample_evidence
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    body = AcceptProposal.status_comment_body(evidence, url)
    assert_includes body, "<!-- status: accepted-design -->"
    assert_includes body, url
  end

  def sample_issue(url)
    {
      "number" => 8,
      "state" => "open",
      "body" => AcceptProposal.with_decision_marker("### Problem\n\n详情", url),
      "labels" => [{"name" => "proposal"}, {"name" => "proposal:needs-design"}]
    }
  end

  def sample_evidence(author: "ShiningRay", url: "https://github.com/o/r/issues/8#issuecomment-123")
    {
      "author" => author,
      "body" => AcceptProposal.verdict_comment("方向成立"),
      "parent" => "https://api.github.com/repos/o/r/issues/8"
    }
  end

  def test_build_plan_produces_expected_actions
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    plan = AcceptProposal.build_plan(8, url, repo: "o/r",
      issue: sample_issue(url), evidence: sample_evidence(url: url))
    assert plan["ok"]
    assert_equal "accepted-design", plan["decision"]
    names = plan["actions"].map { |a| "#{a["action"]}:#{a["name"]}" }
    assert_includes names, "add_label:proposal:accepted-design"
    assert_includes names, "remove_label:proposal:needs-design"
    assert_includes plan["comment"], url
  end

  def test_build_plan_rejects_non_maintainer_author
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    err = assert_raises(SebasAgents::InvalidPlan) do
      AcceptProposal.build_plan(8, url, repo: "o/r",
        issue: sample_issue(url), evidence: sample_evidence(author: "someone", url: url))
    end
    assert_includes err.message, "Maintainer"
  end

  def test_build_plan_rejects_url_of_other_issue
    url = "https://github.com/o/r/issues/9#issuecomment-123"
    err = assert_raises(SebasAgents::InvalidPlan) do
      AcceptProposal.build_plan(8, url, repo: "o/r",
        issue: sample_issue(url), evidence: sample_evidence(url: url))
    end
    assert_includes err.message, "真实父对象"
  end

  def test_acceptance_actions_never_close_or_assign
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    plan = AcceptProposal.build_plan(8, url, repo: "o/r",
      issue: sample_issue(url), evidence: sample_evidence(url: url))
    disallowed = %w[close add_assignee suggest_milestone]
    refute plan["actions"].any? { |a| disallowed.include?(a["action"]) }
  end

  def test_verdict_comment_includes_milestone_when_given
    body = AcceptProposal.verdict_comment("方向成立", milestone: "v0.2.0")
    assert_includes body, "<!-- proposal-verdict: accepted-design -->"
    assert_includes body, "排期裁决：纳入 v0.2.0"
    assert_includes body, "方向成立"
  end

  def test_verdict_comment_omits_schedule_line_without_milestone
    body = AcceptProposal.verdict_comment("方向成立")
    refute_includes body, "排期裁决"
  end

  def fake_milestones(list)
    original = AcceptProposal.method(:gh_json)
    AcceptProposal.define_singleton_method(:gh_json) { |*_args| list }
    yield
  ensure
    AcceptProposal.define_singleton_method(:gh_json, original) if original
  end

  def test_resolve_milestone_by_number
    list = [
      {"number" => 2, "title" => "M4 · v0.2.0", "state" => "open"},
      {"number" => 3, "title" => "M5 · v0.3.0", "state" => "open"}
    ]
    fake_milestones(list) do
      found = AcceptProposal.resolve_milestone("3", repo: "o/r")
      assert_equal "M5 · v0.3.0", found["title"]
    end
  end

  def test_resolve_milestone_by_title
    list = [
      {"number" => 2, "title" => "M4 · v0.2.0", "state" => "open"},
      {"number" => 3, "title" => "M5 · v0.3.0", "state" => "open"}
    ]
    fake_milestones(list) do
      found = AcceptProposal.resolve_milestone("v0.2.0", repo: "o/r")
      assert_equal 2, found["number"]
    end
  end

  def test_resolve_milestone_rejects_missing
    fake_milestones([{"number" => 2, "title" => "M4", "state" => "open"}]) do
      err = assert_raises(AcceptProposal::Failure) { AcceptProposal.resolve_milestone("99", repo: "o/r") }
      assert_includes err.message, "找不到"
    end
  end

  def test_resolve_milestone_rejects_ambiguous_title
    list = [
      {"number" => 2, "title" => "v0.2.0 alpha", "state" => "open"},
      {"number" => 3, "title" => "v0.2.0 beta", "state" => "open"}
    ]
    fake_milestones(list) do
      err = assert_raises(AcceptProposal::Failure) { AcceptProposal.resolve_milestone("v0.2.0", repo: "o/r") }
      assert_includes err.message, "匹配多个"
    end
  end

  def test_build_plan_with_milestone_keeps_schedule_in_evidence
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    evidence = sample_evidence(url: url)
    evidence["body"] = AcceptProposal.verdict_comment("方向成立", milestone: "v0.2.0")
    plan = AcceptProposal.build_plan(8, url, repo: "o/r",
      issue: sample_issue(url), evidence: evidence)
    assert plan["ok"]
    assert_includes plan["comment"], url
  end

  def test_build_plan_rejects_comment_without_verdict_marker
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    evidence = sample_evidence(url: url)
    evidence["body"] = "看起来接受了，但没有标记"
    err = assert_raises(SebasAgents::InvalidPlan) do
      AcceptProposal.build_plan(8, url, repo: "o/r", issue: sample_issue(url), evidence: evidence)
    end
    assert_includes err.message, "proposal-verdict"
  end

  def with_github_stubs(json_handler:, gh_handler: nil)
    original_json = AcceptProposal.method(:gh_json)
    original_gh = AcceptProposal.method(:gh)
    calls = []
    AcceptProposal.define_singleton_method(:gh_json) do |*args|
      calls << [:json, args]
      json_handler.call(*args)
    end
    AcceptProposal.define_singleton_method(:gh) do |*args|
      calls << [:gh, args]
      gh_handler ? gh_handler.call(*args) : ""
    end
    yield calls
  ensure
    AcceptProposal.define_singleton_method(:gh_json, original_json)
    AcceptProposal.define_singleton_method(:gh, original_gh)
  end

  def test_status_comment_exists_checks_all_pages
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    filler = Array.new(100) { |i| {"body" => "comment #{i}"} }
    match = {"body" => "<!-- status: accepted-design -->\nMaintainer 裁决：#{url}"}
    handler = lambda do |*args|
      page = Integer(args.last[/[?&]page=(\d+)/, 1], exception: false) || 1
      raise "unexpected page #{page}" unless [1, 2].include?(page)

      page == 1 ? filler : [match]
    end
    with_github_stubs(json_handler: handler) do
      assert AcceptProposal.status_comment_exists?(8, url, repo: "o/r")
    end
  end

  def test_retry_only_completes_missing_status_and_milestone
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    issue = sample_issue(url).merge(
      "labels" => [{"name" => "proposal"}, {"name" => "proposal:accepted-design"}],
      "milestone" => nil
    )
    evidence = sample_evidence(url: url)
    json_handler = lambda do |*args|
      case args
      in ["api", "user"]
        {"login" => "ShiningRay"}
      in ["api", "repos/o/r/issues/8"]
        issue
      in ["api", "repos/o/r/milestones?state=open&per_page=100"]
        [{"number" => 2, "title" => "v0.2.0"}]
      in ["api", "repos/o/r/issues/comments/123"]
        {"user" => {"login" => "ShiningRay"}, "body" => evidence["body"], "issue_url" => evidence["parent"]}
      in ["api", /comments\?per_page=100&page=1/]
        []
      else
        raise "unexpected json call: #{args.inspect}"
      end
    end
    with_github_stubs(json_handler: json_handler) do |calls|
      out, = capture_io { AcceptProposal.apply(8, "不应重复写入", repo: "o/r", milestone_value: "2") }
      assert_includes out, "补齐未完成步骤"
      gh_calls = calls.select { |kind,| kind == :gh }.map(&:last)
      refute gh_calls.any? { |args| args.include?("issues/8/comments") && !args.join(" ").include?("-f") }
      refute gh_calls.any? { |args| args.include?("--add-label") || args.include?("--remove-label") }
      assert gh_calls.any? { |args| args.join(" ").include?("issues/8/comments") && args.join(" ").include?("-f") }
      assert gh_calls.any? { |args| args.join(" ").include?("-f") && args.join(" ").include?("milestone=2") }
    end
  end

  def test_retry_without_decision_marker_fails_before_writing
    issue = {"number" => 8, "state" => "open", "body" => "no marker",
             "labels" => [{"name" => "proposal"}, {"name" => "proposal:accepted-design"}]}
    json_handler = lambda do |*args|
      case args
      in ["api", "user"] then {"login" => "ShiningRay"}
      in ["api", "repos/o/r/issues/8"] then issue
      else raise "unexpected json call: #{args.inspect}"
      end
    end
    with_github_stubs(json_handler: json_handler) do |calls|
      err = assert_raises(AcceptProposal::Failure) do
        AcceptProposal.apply(8, "x", repo: "o/r")
      end
      assert_includes err.message, "缺裁决证据 marker"
      assert_empty calls.select { |kind,| kind == :gh }
    end
  end

  def retry_evidence_handler(issue, evidence)
    lambda do |*args|
      case args
      in ["api", "user"]
        {"login" => "ShiningRay"}
      in ["api", "repos/o/r/issues/8"]
        issue
      in ["api", "repos/o/r/issues/comments/123"]
        {"user" => {"login" => evidence["author"]}, "body" => evidence["body"], "issue_url" => evidence["parent"]}
      else
        raise "unexpected json call: #{args.inspect}"
      end
    end
  end

  def test_retry_rejects_non_maintainer_evidence_before_writing
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    issue = sample_issue(url).merge("labels" => [{"name" => "proposal"}, {"name" => "proposal:accepted-design"}])
    evidence = sample_evidence(author: "someone", url: url)
    with_github_stubs(json_handler: retry_evidence_handler(issue, evidence)) do |calls|
      err = assert_raises(AcceptProposal::Failure) { AcceptProposal.apply(8, "x", repo: "o/r") }
      assert_includes err.message, "Maintainer"
      assert_empty calls.select { |kind,| kind == :gh }
    end
  end

  def test_retry_rejects_missing_verdict_marker_before_writing
    url = "https://github.com/o/r/issues/8#issuecomment-123"
    issue = sample_issue(url).merge("labels" => [{"name" => "proposal"}, {"name" => "proposal:accepted-design"}])
    evidence = sample_evidence(url: url)
    evidence["body"] = "没有裁决标记"
    with_github_stubs(json_handler: retry_evidence_handler(issue, evidence)) do |calls|
      err = assert_raises(AcceptProposal::Failure) { AcceptProposal.apply(8, "x", repo: "o/r") }
      assert_includes err.message, "proposal-verdict"
      assert_empty calls.select { |kind,| kind == :gh }
    end
  end
end
