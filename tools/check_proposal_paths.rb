#!/usr/bin/env ruby
# frozen_string_literal: true

# Proposal 文档路径守卫：只有 Maintainer/Scribe 一方可以改设计提案正文。
#
# 规则来源：docs/design/process/proposal-lifecycle.md §7。
# 设计意图：外部贡献者与普通协作者只能开 Proposal issue 参与讨论，
# 不能直接投递或改写 docs/design/proposals/ 下的设计文档。
#
# 可执行边界（必须如实说明）：
#   本检查按 PR 作者登录名校验。Scribe 与 Maintainer 共用同一账号，
#   因此这里无法区分「Scribe 在写」与「维护者本人在写」——两者都放行是预期行为。
#   本检查能拦住的是：外部贡献者、其他协作者、以及任何非白名单账号的 PR。
#   它拦不住同账号下的其他 AI 角色（如 Implementer）越权改文档；那由流程纪律约束。
#
# 用法（CI 内）：
#   PR_NUMBER=123 REPO=o/r ruby tools/check_proposal_paths.rb
# 本地自检：
#   ruby tools/check_proposal_paths.rb --files a.md,b.md --author someone [--root .]
require "json"
require "open3"
require "yaml"

module ProposalPaths
  # 受保护的路径：设计提案正文与其入口模板。
  # 不含 docs/design/process/（流程文档由 Scribe 与维护者共同维护，改动更频繁）。
  PROTECTED_PREFIXES = ["docs/design/proposals/"].freeze
  PROTECTED_FILES = [".github/ISSUE_TEMPLATE/proposal.yml"].freeze

  module_function

  def protected?(path)
    PROTECTED_FILES.include?(path) || PROTECTED_PREFIXES.any? { |prefix| path.start_with?(prefix) }
  end

  def protected_paths(files)
    Array(files).select { |path| protected?(path) }
  end

  # 白名单来自 .github/agents.yml 的 maintainers；缺文件或空列表即 fail-closed。
  def maintainers(root)
    path = File.join(root, ".github", "agents.yml")
    unless File.exist?(path)
      raise "缺 #{path}，无法校验 Proposal 文档作者（fail-closed）"
    end

    data = YAML.safe_load_file(path)
    list = Array(data && data["maintainers"]).map(&:to_s).reject(&:empty?)
    raise "#{path} 的 maintainers 为空，无法校验 Proposal 文档作者（fail-closed）" if list.empty?

    list
  end

  # 返回违规说明数组；空数组表示通过。
  def violations(files:, author:, maintainers:)
    touched = protected_paths(files)
    return [] if touched.empty?
    return [] if maintainers.include?(author.to_s)

    [
      "Proposal 文档只能由 Maintainer/Scribe 提交，当前 PR 作者 #{author.inspect} 不在白名单：" \
      "#{touched.join("、")}。请改为开 Proposal issue 参与讨论；" \
      "设计文档由 Scribe 按 Maintainer 指令整理（见 docs/design/process/proposal-lifecycle.md §7）"
    ]
  end
end

def gh_json(*args)
  out, err, status = Open3.capture3("gh", *args)
  raise "gh #{args.join(" ")} 失败：#{err.strip}" unless status.success?

  JSON.parse(out)
end

def parse_flags(argv)
  options = {}
  argv.each_with_index do |arg, index|
    case arg
    when "--files" then options[:files] = argv[index + 1].to_s
    when "--author" then options[:author] = argv[index + 1].to_s
    when "--root" then options[:root] = argv[index + 1].to_s
    end
  end
  options
end

if __FILE__ == $PROGRAM_NAME
  options = parse_flags(ARGV)
  root = options[:root] || Dir.pwd

  files = if options[:files]
    options[:files].split(",").map(&:strip).reject(&:empty?)
  else
    pr = ENV.fetch("PR_NUMBER") { abort "需要 PR_NUMBER 或 --files" }
    repo = ENV.fetch("REPO") { abort "需要 REPO（owner/name）或 --files" }
    gh_json("api", "repos/#{repo}/pulls/#{pr}/files", "--paginate", "--jq", "[.[].filename]")
  end

  author = options[:author] || begin
    pr = ENV.fetch("PR_NUMBER")
    repo = ENV.fetch("REPO")
    gh_json("api", "repos/#{repo}/pulls/#{pr}").dig("user", "login")
  end

  problems = ProposalPaths.violations(files: files, author: author, maintainers: ProposalPaths.maintainers(root))
  if problems.empty?
    touched = ProposalPaths.protected_paths(files)
    puts touched.empty? ? "未触及 Proposal 文档，跳过" : "Proposal 文档作者校验通过：#{author}"
    exit 0
  end

  problems.each { |line| warn "::error::#{line}" }
  exit 1
end
