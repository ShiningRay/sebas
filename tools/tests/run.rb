# frozen_string_literal: true

# tools 测试的统一入口。
#
# 用法：
#   ruby tools/tests/run.rb            # 全量
#   ruby tools/tests/run.rb docs       # 只跑某个域
#   ruby tools/tests/run.rb --list     # 只列会跑的文件
#
# 域：docs / evidence / legacy / process / sebas_process / workflows
#
# 以前 Makefile 与 ci.yml 各自维护一份文件清单，新增测试要改三处，
# 漏改一处就静默不跑。现在清单由目录推导，门禁只需调用本入口。
#
# `legacy` 是过渡域：尚未迁到 tools/tests/<域>/ 的 `tools/test_*.rb`。
# 它在清单里显式出现，而不是被静默忽略——并行分支先合入的新测试若还在旧路径，
# 全量门禁照样会跑到它们，不会因为目录重组而消失。
require "rbconfig"

ROOT = File.expand_path("../..", __dir__)
DOMAINS = %w[docs evidence legacy process sebas_process workflows].freeze

def test_files(domains)
  domains.flat_map do |domain|
    next Dir.glob(File.join(ROOT, "tools", "test_*.rb")) if domain == "legacy"

    Dir.glob(File.join(ROOT, "tools", "tests", domain, "test_*.rb"))
  end.uniq.sort
end

args = ARGV.dup
if args.delete("--list")
  puts test_files(DOMAINS)
  exit 0
end

domains = args.empty? ? DOMAINS : args
unknown = domains - DOMAINS
unless unknown.empty?
  warn "未知测试域：#{unknown.join("、")}（可选：#{DOMAINS.join("、")}）"
  exit 2
end

files = test_files(domains)
if files.empty?
  warn "没有匹配的测试文件（域：#{domains.join("、")}）"
  exit 2
end

legacy = test_files(%w[legacy])
unless legacy.empty?
  warn "提示：以下测试仍在旧路径，建议迁到 tools/tests/<域>/："
  legacy.each { |f| warn "  - #{f.delete_prefix("#{ROOT}/")}" }
end

# 逐文件起子进程：evidence 测试会改写模块级 runner/git_runner 注入点，
# 同进程串跑会把彼此的残留注入串到一起；独立进程也便于定位失败文件。
failures = []
files.each do |file|
  relative = file.delete_prefix("#{ROOT}/")
  puts "\n== #{relative}"
  ok = system(RbConfig.ruby, file)
  failures << relative unless ok
end

puts
if failures.empty?
  puts "全部通过：#{files.length} 个测试文件"
  exit 0
end

puts "失败 #{failures.length}/#{files.length} 个文件："
failures.each { |f| puts "  - #{f}" }
exit 1
