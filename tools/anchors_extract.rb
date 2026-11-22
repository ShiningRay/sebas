# frozen_string_literal: true

# 从 markdown 抽取 `path:line` 引用并生成 anchors.json（#121）。
#
# 用途：`verify_code_anchors` 需要一个可机器核验的锚点清单，但仓库里
# 没有任何地方生成它——本脚本补上这个入口。
#
# 设计要点：
#   1. 只核验本仓库存在的路径。历史调研文档（research/、review/）会引用
#      外部项目（如 autobot）的源码路径，那些路径在本仓库不存在，
#      不能判成「锚点失效」——否则引入 47 处假红（基线实测）。
#   2. 越界行号是硬错误：文件在但行号超出，说明文档已与源码漂移。
#   3. content 取该行实际内容，供 verify_code_anchors 逐字比对。
#   4. 生成物不入库（派生物），在 CI 里即时生成。

require "json"
require "optparse"

module AnchorExtractor
  # file:line 开头，后接可选的 `-N` 与 `,N-M` 组合。
  # 前置字符类排除字母数字与 ./：避免把 `xsrc/a.cr:1` 或 URL 尾部误认。
  REF = %r{(?<![A-Za-z0-9_./-])([A-Za-z0-9_.][A-Za-z0-9_.+/-]*\.[A-Za-z0-9]+):(\d+)((?:-\d+)?(?:,\d+(?:-\d+)?)*)}
  # 只认这些顶层目录下的源码/脚本引用，避免把版本号（如 `1.2:`）当锚点。
  TRACKED_PREFIX = %r{\A(?:src|spec|tools|dev|scripts|examples|lib)/}

  module_function

  # 把 `12`、`12-15`、`12,20-22` 展开为行号数组。
  def line_numbers(start, rest)
    numbers = [start.to_i]
    (rest || "").scan(/-(\d+)|,(\d+)/) do |dash, comma|
      value = (dash || comma).to_i
      numbers << value
      # 区间 `a-b`：把中间行也纳入？不。只核验端点即可——
      # 文档用区间表达「这一带」，逐行展开会把 400 行的段变成 400 条断言，
      # 既冗长又与文档意图不符。
    end
    numbers.uniq
  end

  # 返回 [anchors, skipped, problems]
  #   anchors  —— 可核验项 [{"file","line","content"}]
  #   skipped  —— 本仓库不存在的路径引用（外部项目/已删除文件），不计入
  #   problems —— 需报错项（文件在但越界）
  def extract(paths, root: Dir.pwd)
    anchors = []
    skipped = []
    problems = []

    paths.each do |path|
      full = File.expand_path(path, root)
      next unless File.exist?(full)

      text = File.read(full, encoding: "UTF-8")
      text.each_line.with_index(1) do |line_text, _|
        line_text.scan(REF) do
          match = Regexp.last_match
          file = match[1]
          next unless TRACKED_PREFIX.match?(file)

          target = File.expand_path(file, root)
          unless File.exist?(target)
            # 本仓库没有这个文件：外部项目引用或已删除文件。
            # 不判错（会引入假红），但要报出来供人核对。
            skipped << {"source" => path, "ref" => "#{file}:#{match[2]}#{match[3]}"}
            next
          end

          total = File.read(target, encoding: "UTF-8").lines.length
          contents = File.read(target, encoding: "UTF-8").lines

          line_numbers(match[2], match[3]).each do |number|
            if number < 1 || number > total
              problems << "#{path} 引用 #{file}:#{number}，但该文件只有 #{total} 行"
              next
            end

            content = contents[number - 1].to_s.chomp
            # 指向空行/纯空白行：文档用区间表达「这一带」，起点常落在空行或
            # 注释分隔行上。这类锚点无法逐字比对，且不是漂移信号——记入 skipped。
            if content.strip.empty?
              skipped << {"source" => path, "ref" => "#{file}:#{number}", "reason" => "指向空行"}
              next
            end

            anchors << {
              "file" => file,
              "line" => number,
              "content" => content
            }
          end
        end
      end
    end

    [anchors, skipped, problems]
  end

  # 去重：同一 file:line 在多处被引用时只核验一次。
  def dedupe(anchors)
    anchors.uniq { |anchor| [anchor["file"], anchor["line"]] }
  end

  def run(argv, root: Dir.pwd, out: $stdout, err: $stderr)
    options = {output: nil, json: false, root: nil}
    parser = OptionParser.new do |opts|
      opts.banner = "用法：ruby tools/anchors_extract.rb [选项] <markdown...>"
      opts.on("--output PATH", "写入 JSON 文件（省略则打印到 stdout）") { |v| options[:output] = v }
      opts.on("--json", "以 JSON 输出摘要") { options[:json] = true }
      opts.on("--root PATH", "仓库根（默认当前目录）") { |v| options[:root] = v }
    end
    paths = parser.parse(argv)

    if paths.empty?
      err.puts("至少需要一个 markdown 路径")
      return 2
    end

    base = options[:root] || "."
    root = File.expand_path(base, root)
    anchors, skipped, problems = extract(paths, root: root)
    anchors = dedupe(anchors)

    if !problems.empty?
      problems.each { |problem| err.puts("ERROR #{problem}") }
      err.puts("共 #{problems.length} 处行号越界，拒绝生成 anchors")
      return 1
    end

    payload = JSON.pretty_generate(anchors)
    if options[:output]
      File.write(options[:output], "#{payload}\n", encoding: "UTF-8")
      out.puts("已写入 #{options[:output]}：#{anchors.length} 条锚点，跳过 #{skipped.length} 条外部引用")
    else
      out.puts(payload)
      err.puts("锚点 #{anchors.length} 条，跳过 #{skipped.length} 条外部引用")
    end
    0
  end
end

exit(AnchorExtractor.run(ARGV)) if $PROGRAM_NAME == __FILE__
