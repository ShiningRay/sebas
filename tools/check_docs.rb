#!/usr/bin/env ruby
# frozen_string_literal: true

# 文档链接、失效行号锚与单文件体量检查。
# FAIL（死链、行号锚）退出码 1；WARN（历史存档行号、体量）不阻断。

require "optparse"

module CheckDocs
  LINK_RE = /(?<!\!)\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/
  SKIP_SCHEME = /\A(?:https?:|mailto:|tel:|ftp:|data:|#)/
  LINE_ANCHOR = /(design\.md|development-plan\.md)(?:\s*(?::|：)\s*|\s+(?=L\d))(L?\d+(?:\s*[-–~]\s*\d+)?)/
  LINE_ANCHOR_ALLOW_DIRS = ["docs/design/review/"].freeze

  module_function

  def markdown_files(root, exclude_dirs)
    Dir.glob(File.join(root, "**", "*.md")).sort.reject do |path|
      path.split(/[\\\/]/).any? { |part| part.start_with?(".") || exclude_dirs.include?(part) }
    end
  end

  def read_lines(path)
    File.read(path, encoding: "UTF-8").split("\n", -1)
  end

  def check_links(path, lines, problems)
    base = File.dirname(path)
    lines.each_with_index do |line, index|
      line.scan(LINK_RE) do |match|
        target = match.first
        next if SKIP_SCHEME.match?(target)

        core = target.split("#", 2).first
        next if core.empty?

        resolved = File.expand_path(core, base)
        next if File.exist?(resolved)

        problems << ["FAIL", path, index + 1, "死链：#{target}（解析为 #{resolved}）"]
      end
    end
  end

  def check_line_anchors(path, lines, problems, repo_root)
    relative = path.delete_prefix(repo_root).delete_prefix("/").tr("\\", "/")
    level = LINE_ANCHOR_ALLOW_DIRS.any? { |dir| relative.start_with?(dir) } ? "WARN" : "FAIL"
    lines.each_with_index do |line, index|
      line.scan(LINE_ANCHOR) do
        anchor = Regexp.last_match(0)
        note = level == "WARN" ? "（存档报告，允许保留）" : "，须改写为 §锚或指向分册文件"
        problems << [level, path, index + 1, "行号锚 `#{anchor}`#{note}"]
      end
    end
  end

  def run(argv, repo_root: Dir.pwd, out: $stdout, err: $stderr)
    options = {root: "docs", max_lines: 400, exclude: %w[node_modules lib vendor bin]}
    OptionParser.new do |parser|
      parser.on("--root PATH") { |value| options[:root] = value }
      parser.on("--max-lines N", Integer) { |value| options[:max_lines] = value }
      parser.on("--exclude LIST") { |value| options[:exclude] = value.split(",") }
    end.parse!(argv)

    root = File.expand_path(options[:root], repo_root)
    unless Dir.exist?(root)
      err.puts("root 不存在：#{root}")
      return 2
    end

    problems = []
    files = markdown_files(root, options[:exclude])
    files.each do |path|
      lines = read_lines(path)
      if lines.length > options[:max_lines]
        problems << ["WARN", path, 0, "体量 #{lines.length} 行 > 阈值 #{options[:max_lines]} 行，建议拆分或收敛"]
      end
      check_links(path, lines, problems)
      check_line_anchors(path, lines, problems, repo_root)
    end

    problems.sort_by! { |level, path, line, _| [level == "FAIL" ? 0 : 1, path, line] }
    problems.each do |level, path, line, message|
      relative = path.delete_prefix(repo_root).delete_prefix("/").tr("\\", "/")
      location = line.zero? ? relative : "#{relative}:#{line}"
      out.puts("#{level} #{location} | #{message}")
    end

    fails = problems.count { |problem| problem.first == "FAIL" }
    warns = problems.count { |problem| problem.first == "WARN" }
    out.puts("\n检查 #{files.length} 个 Markdown 文件：FAIL #{fails}，WARN #{warns}")
    fails.zero? ? 0 : 1
  rescue OptionParser::ParseError => e
    err.puts(e.message)
    2
  end
end

exit CheckDocs.run(ARGV) if $PROGRAM_NAME == __FILE__