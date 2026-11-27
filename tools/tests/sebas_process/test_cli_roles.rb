# frozen_string_literal: true

# CLI 角色面：roles / --one-line / --prompt-only 的输出契约与 unknown 子命令。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class CliRolesTest < Minitest::Test
  include CliHelpers

  def test_unknown_command_returns_usage
    status, out, = run_cli(["nope"])
    assert_equal 2, status
    assert_includes out, "usage_error"
  end

  def test_roles_lists_all
    status, out, = run_cli(["roles"])
    assert_equal 0, status
    assert_includes out, "release-manager"
  end

  def test_role_prompt_uses_real_commands
    status, out, = run_cli(%w[roles implementer --json])
    assert_equal 0, status
    documented = JSON.parse(out)["commands"]
    help_out = StringIO.new
    SebasAgents::CLI.new(out: help_out, err: StringIO.new).run(["help"])
    documented.each do |command|
      subcommand = command.split[2]
      assert_includes help_out.string, subcommand
    end
  end

    def test_oneline_is_single_line_for_every_role
    %w[implementer verifier triager scribe release-manager maintainer].each do |role|
      status, out, = run_cli(["roles", role, "--one-line"])
      assert_equal 0, status, role
      assert_equal 1, out.lines.length, "#{role} 的一句话必须是一行"
      assert_includes out, "sebas"
    end
  end

  def test_oneline_all_roles
    status, out, = run_cli(%w[roles --one-line])
    assert_equal 0, status
    assert_equal SebasAgents::RolePrompts::ROLES.length, out.lines.length
    assert_includes out, "Implementer"
    assert_includes out, "Release Manager"
  end

  def test_oneline_names_the_first_command
    status, out, = run_cli(%w[roles implementer --one-line])
    assert_equal 0, status
    assert_includes out, "ruby tools/sebas-process next"
    assert_includes out, "verify merge"
    assert_includes out, "禁 force-push"
  end

  def test_role_prompt_is_plain_text_ready_to_paste
    %w[implementer verifier triager scribe release-manager maintainer].each do |role|
      status, out, = run_cli(["roles", role, "--prompt-only"])
      assert_equal 0, status, role
      assert_includes out, "角色：sebas #{role}"
      assert_includes out, "权限边界"
      assert_includes out, "第一步"
      assert_includes out, "停止条件"
      assert_includes out, "退出码"
      refute out.start_with?("{"), "prompt-only 不应输出 JSON"
    end
  end

  def role_display(role)
    role.split("-").map(&:capitalize).join(" ")
  end

  def test_role_prompt_forbids_writes_for_read_only_roles
    %w[verifier].each do |role|
      _status, out, = run_cli(["roles", role, "--prompt-only"])
      assert_includes out, "只读"
      assert_includes out, "禁止："
    end
  end

  def test_prompt_only_requires_role
    status, out, = run_cli(%w[roles --prompt-only])
    assert_equal 2, status
    assert_includes out, "usage_error"
  end

  def test_roles_without_role_lists_all
    status, out, = run_cli(["roles"])
    assert_equal 0, status
    payload = JSON.parse(out)["roles"]
    assert_equal SebasAgents::RolePrompts::ROLES.sort, payload.keys.sort
  end
end
