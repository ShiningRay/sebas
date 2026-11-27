# frozen_string_literal: true

# Proposal 文档路径守卫的回归。
# 规则：docs/design/proposals/ 与 proposal 模板只能由 Maintainer/Scribe 一方改动。
# 边界如实记录：白名单按登录名校验，Scribe 与 Maintainer 同账号，无法区分二者。

require_relative "../support/boot"
require_relative "../../check_proposal_paths"

class CheckProposalPathsTest < Minitest::Test
  P = ProposalPaths

  def test_protects_proposal_docs
    assert P.protected?("docs/design/proposals/parallel-implementers.md")
  end

  def test_protects_proposal_template
    assert P.protected?(".github/ISSUE_TEMPLATE/proposal.yml")
  end

  def test_does_not_protect_other_docs
    refute P.protected?("docs/design/process/scribe.md")
    refute P.protected?("docs/design/spec/07-orchestration.md")
    refute P.protected?("docs/design/proposals")  # 目录本身不是文件
  end

  def test_does_not_protect_unrelated_template
    refute P.protected?(".github/ISSUE_TEMPLATE/bug_report.yml")
  end

  def test_filters_only_protected
    files = [
      "docs/design/proposals/a.md",
      "src/main.cr",
      "docs/design/process/b.md",
      ".github/ISSUE_TEMPLATE/proposal.yml"
    ]
    assert_equal ["docs/design/proposals/a.md", ".github/ISSUE_TEMPLATE/proposal.yml"], P.protected_paths(files)
  end

  def test_maintainer_may_edit
    assert_empty P.violations(
      files: ["docs/design/proposals/a.md"], author: "ShiningRay", maintainers: ["ShiningRay"]
    )
  end

  def test_outsider_is_blocked
    problems = P.violations(
      files: ["docs/design/proposals/a.md"], author: "outsider", maintainers: ["ShiningRay"]
    )
    assert_equal 1, problems.length
    assert_includes problems.first, "Proposal 文档只能由 Maintainer/Scribe 提交"
    assert_includes problems.first, "proposal-lifecycle.md"
  end

  def test_outsider_may_edit_unrelated_paths
    assert_empty P.violations(files: ["src/main.cr"], author: "outsider", maintainers: ["ShiningRay"])
  end

  def test_outsider_blocked_even_with_many_protected_files
    files = ["docs/design/proposals/a.md", "docs/design/proposals/b.md"]
    problems = P.violations(files: files, author: "outsider", maintainers: ["ShiningRay"])
    assert_includes problems.first, "docs/design/proposals/a.md"
    assert_includes problems.first, "docs/design/proposals/b.md"
  end

  def test_author_comparison_is_case_sensitive
    # 登录名大小写敏感地参与比较：避免形似账号绕过白名单。
    problems = P.violations(
      files: ["docs/design/proposals/a.md"], author: "shiningray", maintainers: ["ShiningRay"]
    )
    assert_equal 1, problems.length
  end

  def test_multiple_maintainers_all_allowed
    list = %w[alice bob]
    assert_empty P.violations(files: ["docs/design/proposals/a.md"], author: "bob", maintainers: list)
  end

  def test_maintainers_read_from_agents_yml
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".github"))
      File.write(File.join(dir, ".github", "agents.yml"), "maintainers:\n  - ShiningRay\n  - alice\n", encoding: "UTF-8")
      assert_equal %w[ShiningRay alice], P.maintainers(dir)
    end
  end

  def test_missing_agents_yml_fails_closed
    Dir.mktmpdir do |dir|
      err = assert_raises(RuntimeError) { P.maintainers(dir) }
      assert_includes err.message, "fail-closed"
    end
  end

  def test_empty_maintainers_fails_closed
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".github"))
      File.write(File.join(dir, ".github", "agents.yml"), "maintainers: []\n", encoding: "UTF-8")
      err = assert_raises(RuntimeError) { P.maintainers(dir) }
      assert_includes err.message, "fail-closed"
    end
  end
end
