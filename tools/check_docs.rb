#!/usr/bin/env ruby
# frozen_string_literal: true

# 文档链接、失效行号锚、单文件体量与长行检查。
# FAIL（死链、行号锚）退出码 1；WARN（历史存档行号、体量、长行）不阻断。
#
# 体量口径不止物理行数：Markdown 段落里的长行在编辑器/网页里会折成多个屏幕行，
# 只数换行符会让「一行写一千字」绕过 400 行阈值。故在物理行之外再查两项：
#   - 等效屏幕行：按显示列宽（CJK 记 2 列）折算的阅读行数，超 max_lines 告警；
#   - 超长单行：单个物理行的显示宽度超 max_line_columns 时按文件汇总告警。
# 长行不能靠硬折行消除——CommonMark 把段落内软换行渲染成空格，中文会凭空多空格，
# 表格行与代码块也不能折——只能在章节边界拆分或改写为子列表/表格。
# 两项新检查豁免 docs/design/review/ 历史存档，理由见 LONG_LINE_SKIP_DIRS。

require "optparse"

module CheckDocs
  LINK_RE = /(?<!\!)\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/
  SKIP_SCHEME = /\A(?:https?:|mailto:|tel:|ftp:|data:|#)/
  LINE_ANCHOR = /(design\.md|development-plan\.md)(?:\s*(?::|：)\s*|\s+(?=L\d))(L?\d+(?:\s*[-–~]\s*\d+)?)/
  LINE_ANCHOR_ALLOW_DIRS = ["docs/design/review/"].freeze
  # 历史存档是当时的快照，改写会破坏证据价值：给存档报「请拆小节/拆子列表」
  # 既不可执行，也会让每次门禁长期挂着一批消不掉的告警。
  # 因此新增的两项体量检查（等效屏幕行、超长单行）跳过存档目录；
  # 物理行超限沿用旧行为照报。research/ 是可维护文档，不在豁免内。
  LONG_LINE_SKIP_DIRS = ["docs/design/review/"].freeze
  FENCE_OPEN = /\A {0,3}(`{3,}|~{3,})(.*)\z/
  FENCE_CLOSE = /\A {0,3}(`{3,}|~{3,})\s*\z/

  # 东亚宽字符：终端、编辑器与浏览器按 2 列渲染。
  # 覆盖 CJK 标点/假名/谚文/全角符号/emoji 与 CJK 扩展区；
  # 0x2010–0x2E7F 之间是西文标点与符号，仍记 1 列，故不整体纳入。
  WIDE_RANGES = [
    0x1100..0x115F, 0x2E80..0x303E, 0x3041..0x33FF, 0x3400..0x4DBF,
    0x4E00..0x9FFF, 0xA000..0xA4CF, 0xAC00..0xD7A3, 0xF900..0xFAFF,
    0xFE10..0xFE19, 0xFE30..0xFE6F, 0xFF00..0xFF60, 0xFFE0..0xFFE6,
    0x1F300..0x1F64F, 0x1F900..0x1F9FF, 0x20000..0x3FFFD
  ].freeze

  module_function

  def markdown_files(root, exclude_dirs)
    Dir.glob(File.join(root, "**", "*.md")).sort.reject do |path|
      path.split(/[\\\/]/).any? { |part| part.start_with?(".") || exclude_dirs.include?(part) }
    end
  end

  def read_lines(path)
    File.read(path, encoding: "UTF-8").lines(chomp: true)
  end

  # 单字符显示列宽；宽字符 2 列，其余 1 列。
  def display_width(text)
    text.each_char.sum { |char| wide?(char) ? 2 : 1 }
  end

  def wide?(char)
    code = char.ord
    WIDE_RANGES.any? { |range| range.cover?(code) }
  end

  # 等效屏幕行：按 CommonMark 的渲染语义估算阅读行数。
  # 段落续行合并时各计一个分隔空格；列表项可含续行，标题必须立即收块。
  # 表格行与代码块横向滚动不折行，每行占一屏。
  # 逐行 ceil 会高估，全篇总量又会低估，故按块累加。
  def screen_lines(lines, columns)
    fenced = nil
    rows = 0
    block_width = 0
    block_open = false
    flush = lambda do
      rows += [(block_width.to_f / columns).ceil, 1].max if block_open
      block_width = 0
      block_open = false
    end
    append = lambda do |width|
      block_width += 1 if block_open # 软换行渲染为一个空格
      block_width += width
      block_open = true
    end

    lines.each do |line|
      if fenced
        rows += 1
        fenced = nil if closing_fence?(line, fenced)
      elsif (opening = opening_fence(line))
        flush.call
        rows += 1
        fenced = opening
      elsif line.strip.empty?
        flush.call
      elsif table_line?(line)
        flush.call
        rows += 1
      elsif heading?(line)
        flush.call
        append.call(display_width(line))
        flush.call
      elsif list_item?(line)
        flush.call
        append.call(display_width(line))
      else
        append.call(display_width(line))
      end
    end
    flush.call
    rows
  end

  # 记录开栏字符与长度；闭栏须同字符、长度不短于开栏且后面只有空白。
  def opening_fence(line)
    match = FENCE_OPEN.match(line)
    return nil unless match

    marker = match[1]
    # 反引号开栏的 info string 不得再含反引号；否则该围栏不成立。
    return nil if marker.start_with?("`") && match[2].include?("`")

    {char: marker[0], length: marker.length}
  end

  def closing_fence?(line, opening)
    match = FENCE_CLOSE.match(line)
    return false unless match

    marker = match[1]
    marker[0] == opening[:char] && marker.length >= opening[:length]
  end

  def list_item?(line)
    line.lstrip.match?(/\A(?:[-*+]|\d+\.)\s/)
  end

  def heading?(line)
    line.lstrip.start_with?("#")
  end

  # 每个文件的超长物理行：返回 [行号, 显示宽度] 列表。
  # 跳过两类无法靠「重排结构」收窄的行：
  #   - 代码块：拆行破坏可复制性，横向滚动是合理用法；
  #   - 表格行：宽度 = 各列内容之和，收窄只能删列或删信息，属内容决策而非排版问题。
  # 段落与列表项超宽可以拆成子列表或小节，是本检查要报的信号。
  # 表格的阅读体量由等效屏幕行（每行占一屏）覆盖。
  def long_lines(lines, max_columns)
    fenced = nil
    long = []
    lines.each_with_index do |line, index|
      if fenced
        fenced = nil if closing_fence?(line, fenced)
        next
      end
      if (opening = opening_fence(line))
        fenced = opening
        next
      end
      next if table_line?(line)

      width = display_width(line)
      long << [index + 1, width] if width > max_columns
    end
    long
  end

  def table_line?(line)
    line.lstrip.start_with?("|")
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

  # 体量检查：物理行超限优先报；物理行未超但等效屏幕行超限时，单独说明是长行所致，
  # 避免同一文件两条告警指向同一件事。
  def check_size(path, lines, problems, options, repo_root: Dir.pwd)
    max_lines = options[:max_lines]
    columns = options[:display_columns]
    if max_lines.positive? && lines.length > max_lines
      problems << ["WARN", path, 0, "体量 #{lines.length} 行 > 阈值 #{max_lines} 行，建议拆分或收敛"]
    end

    return if skip_long_lines?(path, repo_root)

    if max_lines.positive? && lines.length <= max_lines && columns.positive?
      screen = screen_lines(lines, columns)
      if screen > max_lines
        problems << ["WARN", path, 0,
          "等效屏幕行 #{screen}（按 #{columns} 列折行）> 阈值 #{max_lines} 行，长行压缩了物理行数，建议拆分"]
      end
    end

    max_columns = options[:max_line_columns]
    return unless max_columns.positive?

    long = long_lines(lines, max_columns)
    return if long.empty?

    longest = long.max_by { |_number, width| width }
    problems << ["WARN", path, longest.first,
      "#{long.length} 行显示宽度 > #{max_columns} 列（最长 #{longest.last} 列），" \
      "建议拆为子列表、表格或小节"]
  end

  def skip_long_lines?(path, repo_root)
    relative = path.delete_prefix(repo_root).delete_prefix("/").tr("\\", "/")
    LONG_LINE_SKIP_DIRS.any? { |dir| relative.start_with?(dir) }
  end

  def run(argv, repo_root: Dir.pwd, out: $stdout, err: $stderr)
    options = {
      root: "docs", max_lines: 400, display_columns: 100, max_line_columns: 400,
      exclude: %w[node_modules lib vendor bin]
    }
    OptionParser.new do |parser|
      parser.on("--root PATH") { |value| options[:root] = value }
      parser.on("--max-lines N", Integer, "单文件物理行阈值（默认 400，0 表示不设上限）") do |value|
        options[:max_lines] = value
      end
      parser.on("--display-columns N", Integer, "折算屏幕行的视口列数（默认 100，0 关闭该检查）") do |value|
        options[:display_columns] = value
      end
      parser.on("--max-line-columns N", Integer, "单行显示宽度阈值（默认 400，0 关闭该检查）") do |value|
        options[:max_line_columns] = value
      end
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
      check_size(path, lines, problems, options, repo_root: repo_root)
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
