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
  # 不要求扩展名：`tools/sebas-process:123` 这类无扩展名脚本也是有效引用；
  # 版本号（`1.2:3`）与 URL 由下面的前缀过滤与前置字符类共同排除。
  REF = %r{(?<![A-Za-z0-9_./-])([A-Za-z0-9_.][A-Za-z0-9_.+/-]*):(\d+)((?:-\d+)?(?:,\d+(?:-\d+)?)*)}
  # 只认这些顶层目录下的源码/脚本引用，避免把版本号（如 `1.2:`）当锚点。
  TRACKED_PREFIX = %r{\A(?:src|spec|tools|dev|scripts|examples|lib)/}
  # 历史存档目录：这里记录的是当时的调研结论，可能引用外部项目（如 autobot）
  # 或已被删除的文件，按「留档」处理。当前文档则严格判定——文件缺失即报错，
  # 否则本地文件被删除或拼错时会被静默放过（CodeRabbit Major）。
  # 与 Verifier::ARCHIVE_DIRS 同口径。
  ARCHIVE_DIRS = ["docs/design/review/", "docs/design/research/"].freeze

  module_function

  def archive?(path, root)
    relative = File.expand_path(path, root)
      .delete_prefix(File.expand_path(root) + File::SEPARATOR).tr("\\", "/")
    ARCHIVE_DIRS.any? { |dir| relative.start_with?(dir) }
  end

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
  #   skipped  —— 有意不核验项：存档目录里的缺失引用、指向空行的锚点
  #   problems —— 需报错项：当前文档里的缺失引用、行号越界、输入文件不存在
  def extract(paths, root: Dir.pwd)
    anchors = []
    skipped = []
    problems = []

    paths.each do |path|
      full = File.expand_path(path, root)
      unless File.exist?(full)
        # 显式输入却读不到：不能让「文档没有锚点」与「文档没被读取」不可区分。
        problems << "输入文件不存在：#{path}"
        next
      end

      archived = archive?(path, root)
      text = File.read(full, encoding: "UTF-8")
      # 先剥掉 URL，再扫引用：`https://example.org/search?q=src/remote.cr:999`
      # 里的 `src/remote.cr:999` 会被 REF 匹配（前置字符 `=` 不在排除类里），
      # 目标不存在时会让正常的外部链接把文档门禁弄红。
      text = text.gsub(%r{\b(?:https?|ftp)://\S+}, "")
      text.each_line.with_index(1) do |line_text, _|
        line_text.scan(REF) do
          match = Regexp.last_match
          # 规范化 `./` 前缀：`./src/x.cr:12` 与 `src/x.cr:12` 是同一引用。
          file = match[1].sub(%r{\A\./}, "")
          next unless TRACKED_PREFIX.match?(file)

          target = File.expand_path(file, root)
          unless File.exist?(target)
            if archived
              skipped << {"source" => path, "ref" => "#{file}:#{match[2]}#{match[3]}",
                          "reason" => "存档引用，目标不在本仓库"}
            else
              problems << "#{path} 引用 #{file}:#{match[2]}，但本仓库没有该文件"
            end
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
