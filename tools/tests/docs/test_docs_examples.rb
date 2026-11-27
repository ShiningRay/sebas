# frozen_string_literal: true

# 把 docs/design/process 里的 Ruby 示例当代码跑：保证文档指向的标识符真实存在。
# 只做静态存在性检查（不执行示例），避免文档与 tools/agents 漂移。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class DocsExamplesTest < Minitest::Test
  ROOT = RepoPaths::ROOT
  PROCESS_DIR = File.join(ROOT, "docs", "design", "process")

  # 文档中出现、且必须真实存在的入口。
  REQUIRED_CONSTANTS = {
    "Policy::Selection" => SebasAgents::Policy::Selection,
    "Policy::Dependencies" => SebasAgents::Policy::Dependencies,
    "Policy::Milestones" => SebasAgents::Policy::Milestones,
    "Triager" => SebasAgents::Triager,
    "Verifier" => SebasAgents::Verifier,
    "VerifyChecks" => SebasAgents::VerifyChecks,
    "Release" => SebasAgents::Release,
    "GithubGateway" => SebasAgents::GithubGateway
  }.freeze

  def documents
    Dir.glob(File.join(PROCESS_DIR, "*.md"))
  end

  def test_documents_exist
    refute_empty documents
  end

  def test_no_reference_pseudocode_headings
    offenders = documents.select { |path| File.read(path, encoding: "UTF-8").include?("参考实现：") }
    assert_empty offenders.map { |path| File.basename(path) }
  end

  def test_documented_methods_exist
    missing = []
    documents.each do |path|
      File.read(path, encoding: "UTF-8").scan(/SebasAgents::([A-Z][\w:]+)\.(\w+)/) do |klass, method|
        target = REQUIRED_CONSTANTS[klass]
        missing << "#{klass}.#{method}" if target && !target.respond_to?(method)
      end
    end
    assert_empty missing.uniq
  end

  def test_documented_constants_resolve
    missing = REQUIRED_CONSTANTS.reject { |_name, value| value }
    assert_empty missing.keys
  end

  def test_documented_cli_subcommands_exist
    help = capture_help
    documents.each do |path|
      File.read(path, encoding: "UTF-8").scan(/ruby tools\/sebas-process ([\w-]+)/).flatten.uniq.each do |subcommand|
        next if subcommand.start_with?("-")
        assert_includes help, subcommand, "#{File.basename(path)} 引用了不存在的子命令 #{subcommand}"
      end
    end
  end

  def test_documented_flags_exist
    help = capture_help
    documents.each do |path|
      File.read(path, encoding: "UTF-8").scan(/ruby tools\/sebas-process[^\n`]*--([a-z-]+)/).flatten.uniq.each do |flag|
        assert_includes help, "--#{flag}", "#{File.basename(path)} 引用了帮助中不存在的选项 --#{flag}"
      end
    end
  end

  def test_prompt_only_is_documented
    quickstart = File.read(File.join(PROCESS_DIR, "quickstart.md"), encoding: "UTF-8")
    assert_includes quickstart, "--prompt-only"
  end

  def test_quickstart_commands_match_roles
    quickstart = File.read(File.join(PROCESS_DIR, "quickstart.md"), encoding: "UTF-8")
    SebasAgents::RolePrompts::ROLES.each do |role|
      writeup = SebasAgents::RolePrompts.writeup(role)
      writeup["commands"].each do |command|
        subcommand = command.split[2]
        assert_includes quickstart, subcommand, "quickstart 未覆盖 #{role} 的 #{subcommand}"
      end
    end
  end

  private

  def capture_help
    out = StringIO.new
    SebasAgents::CLI.new(out: out, err: StringIO.new).run(["help"])
    out.string
  end
end
