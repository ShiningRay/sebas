# frozen_string_literal: true

# JSON 块解析（重复 / 非法 / CRLF）与 CommandRunner 的 dry-run 写保护。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class JsonBlockTest < Minitest::Test
  def test_rejects_duplicate_blocks
    body = "```json automation\n{\"kind\":\"work_package\"}\n```\n```json automation\n{\"kind\":\"tracking\"}\n```\n"
    assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::JsonBlock.one(body, "automation", subject: "issue #1")
    end
  end

  def test_rejects_invalid_json
    assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::JsonBlock.one("```json automation\n{nope}\n```\n", "automation", subject: "issue #1")
    end
  end

  def test_ignores_unlabelled_json_fence
    body = "```json\n{\"kind\":\"tracking\"}\n```\n"
    assert_nil SebasAgents::JsonBlock.one(body, "automation", subject: "issue #1")
  end

  # Windows 客户端写的 issue body 是 CRLF；曾导致所有元数据"看起来不存在"。
  def test_parses_crlf_body
    body = "## Automation\r\n\r\n```json automation\r\n{\"schema\":1,\"kind\":\"work_package\"}\r\n```\r\n"
    parsed = SebasAgents::JsonBlock.one(body, "automation", subject: "issue #1")
    assert_equal "work_package", parsed["kind"]
    assert SebasAgents::JsonBlock.present?(body, "automation")
  end

  def test_parses_mixed_line_endings
    body = "text\r\n```json automation\n{\"kind\":\"tracking\"}\r\n```\n"
    assert_equal "tracking", SebasAgents::JsonBlock.one(body, "automation", subject: "issue #1")["kind"]
  end
end

class DryRunGuardTest < Minitest::Test
  # 复核列出的真实写命令形态，全部必须被拦。
  WRITE_COMMANDS = [
    %w[git push origin main],
    %w[git commit -m x],
    %w[git tag v1.0.0],
    %w[git checkout -b feat/x],
    %w[git switch main],
    %w[git reset --hard],
    %w[git add -A],
    %w[git stash],
    ["git", "-C", "/repo", "commit", "-m", "x"],
    ["git", "--git-dir", "/repo/.git", "commit", "-m", "x"],
    ["gh", "issue", "edit", "1", "--add-label", "bug"],
    ["gh", "issue", "close", "1"],
    ["gh", "issue", "comment", "1", "--body", "x"],
    ["gh", "issue", "develop", "1"],
    ["gh", "pr", "merge", "5", "--squash"],
    ["gh", "pr", "create", "--title", "t"],
    ["gh", "pr", "update-branch", "5"],
    ["gh", "-R", "o/r", "pr", "merge", "5"],
    ["gh", "--repo", "o/r", "issue", "comment", "1", "--body", "x"],
    ["gh", "label", "create", "bug"],
    ["gh", "api", "repos/o/r/issues/1", "-X", "POST", "-f", "body=x"],
    ["gh", "api", "repos/o/r/issues/1/comments", "-f", "body=x"],
    ["gh", "api", "repos/o/r/issues/1/comments", "-fbody=x"],
    ["gh", "api", "repos/o/r/issues", "--input", "payload.json"],
    ["gh", "api", "--method=POST", "repos/o/r/issues"],
    ["gh", "api", "-X", "DELETE", "repos/o/r/issues/1"],
    ["gh", "release", "create", "v1.0.0"],
    ["gh", "release", "upload", "v1", "f.zip"]
  ].freeze

  READ_COMMANDS = [
    %w[git log --oneline],
    %w[git describe --tags --abbrev=0],
    %w[git rev-parse HEAD],
    %w[git status --short],
    ["git", "-C", "/repo", "log", "--oneline"],
    ["gh", "api", "repos/o/r/issues"],
    ["gh", "api", "-X", "GET", "repos/o/r/issues", "-f", "state=open"],
    # graphql 的 -f 只是查询变量，必须放行，否则默认 next 在有 open PR 时必失败
    ["gh", "api", "graphql", "-f", "query=query{viewer{login}}"],
    ["gh", "pr", "list", "--json", "number"],
    ["gh", "pr", "view", "5", "--json", "state"],
    ["gh", "issue", "view", "1", "--json", "body"],
    ["gh", "issue", "list", "--json", "number"],
    ["gh", "-R", "o/r", "issue", "view", "1"],
    ["gh", "status"]
  ].freeze

  def test_write_commands_are_never_executed
    WRITE_COMMANDS.each do |argv|
      runner = SebasAgents::CommandRunner.new(dry_run: true)
      refute runner.send(:read_only?, argv), "未拦截写命令：#{argv.join(" ")}"
      result = runner.capture(*argv)
      assert result.success?, "dry-run 应返回假成功：#{argv.join(" ")}"
      assert_equal "", result.stdout, "dry-run 不得返回伪数据：#{argv.join(" ")}"
    end
  end

  def test_read_commands_are_executed
    READ_COMMANDS.each do |argv|
      runner = SebasAgents::CommandRunner.new(dry_run: true)
      assert runner.send(:read_only?, argv), "误把只读命令当写：#{argv.join(" ")}"
    end
  end

  def test_unknown_command_is_blocked_by_default
    # 白名单语义：无法确认只读的命令默认不执行。
    runner = SebasAgents::CommandRunner.new(dry_run: true)
    refute runner.send(:read_only?, ["curl", "https://example.com"]), "未知命令应默认拦截"
    refute runner.send(:read_only?, ["gh", "extension", "exec", "x"]), "未知 gh 子命令应默认拦截"
  end

  def test_apply_mode_allows_writes
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    refute runner.dry_run?
  end

  # 断言子进程真的被调用，而不是只看 calls 记录（记录在拦截前就写了）。
  def test_write_authorization_is_scoped
    add = ["gh", "issue", "edit", "39", "--repo", "o/r", "--add-label", "agent:in-progress"]
    merge = ["gh", "pr", "merge", "5"]
    executed = []

    Open3.singleton_class.alias_method(:__orig_capture3, :capture3)
    Open3.define_singleton_method(:capture3) do |*argv, **_opts|
      executed << argv
      ["", "", Struct.new(:success?).new(true)]
    end

    begin
      runner = SebasAgents::CommandRunner.new(dry_run: true)
      runner.capture(*add)
      runner.capture(*merge)
      assert_empty executed, "dry-run 不得真正执行写命令"

      runner.with_write(:add_label) { runner.capture(*add) }
      assert_equal [add], executed, "授权后 add-label 必须真实执行"

      runner.with_write(:add_label) { runner.capture(*merge) }
      assert_empty executed.select { |c| c.include?("merge") }, "授权 add-label 不应放行 merge"

      runner.capture(*add)
      assert_equal 1, executed.count { |c| c.include?("--add-label") }, "离开授权后恢复拦截"
    ensure
      Open3.singleton_class.alias_method(:capture3, :__orig_capture3)
    end
  end

  # 重试耗尽后，错误必须带 command 与 stderr，否则上游无法定位。
  def test_retry_exhaustion_keeps_command_context
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    calls = 0
    runner.define_singleton_method(:with_retry) do |&block|
      block.call
    end
    runner.singleton_class.send(:remove_method, :with_retry)
    runner.define_singleton_method(:with_retry) do
      calls += 1
      SebasAgents::CommandRunner::Result.new(stdout: "", stderr: "unexpected EOF\n",
        status: Struct.new(:success?).new(false))
    end
    assert_raises(SebasAgents::CommandError) { runner.run!("gh", "api", "x") }
    error = begin
      runner.run!("gh", "api", "x")
    rescue SebasAgents::CommandError => e
      e
    end
    assert_equal ["gh", "api", "x"], error.command
    assert_includes error.stderr.to_s, "EOF"
    assert_includes error.message, "gh api x"
  end
end
