# frozen_string_literal: true

# oneline.md 的每一行必须与 RolePrompts::ONELINE 完全一致，避免速查表与工具漂移。
require "minitest/autorun"
require_relative "agents/lib/sebas_agents"

class OnelineSheetTest < Minitest::Test
  SHEET = File.expand_path("../docs/design/process/oneline.md", __dir__)

  def sheet
    @sheet ||= File.read(SHEET, encoding: "UTF-8")
  end

  def fenced_lines
    sheet.scan(/^```text\n(.+?)^```$/m).map { |match| match.first.strip }
  end

  def test_every_role_has_exactly_one_line
    assert_equal SebasAgents::RolePrompts::ROLES.length, fenced_lines.length
  end

  def test_sheet_matches_tool_output
    expected = SebasAgents::RolePrompts::ROLES.map { |role| SebasAgents::RolePrompts.oneline(role) }
    assert_equal expected, fenced_lines
  end

  def test_each_line_names_its_role
    SebasAgents::RolePrompts::ROLES.each_with_index do |role, index|
      label = role.split("-").map(&:capitalize).join(" ")
      assert_includes fenced_lines[index], label, "第 #{index + 1} 行应属于 #{label}"
    end
  end

  def test_each_line_has_a_command
    fenced_lines.each do |line|
      assert_includes line, "ruby tools/sebas-process", "每行必须给出入口命令"
    end
  end

  def test_sheet_documents_the_generator
    assert_includes sheet, "roles --one-line"
  end
end
