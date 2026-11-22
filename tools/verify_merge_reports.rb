# frozen_string_literal: true

# 把 verify 的分散报告汇总成 verification.json（#122）。
#
# 为什么要独立成文件：这段逻辑此前内联在 workflow 的 ruby -e 里，
# 无法本地测试、也难审。抽出来后既能在测试里直接跑，也让 workflow
# 只负责「取 base 脚本 → 执行 → 上传」。
#
# 输入（均在 --out 目录下，缺文件不报错但要如实反映）：
#   anchors_report.json      verify anchors 的报告
#   anchors_extract.txt      生成器的 stdout+stderr（含 ERROR 行与 exit 码）
#   docs_report_N.json       verify docs 的分批报告（N 从 1 开始）
#   docs_failures.txt        docs 侧执行/结构失败记录（每行一条）
#
# 输出：verification.json（含 conclusion / counts / items / observed）
#
# ## fail-closed 原则
#
# 「工具挂了」与「核验通过」必须可区分。任一非零退出、结构非法的报告、
# 或本应产出的报告缺失，都必须转成 blocker，而不是当作「无问题」跳过。
# 这条直接对应 CodeRabbit 在 PR #129 报的 CWE-636（工具异常被吞掉后放行）。

require "json"

module VerifyMergeReports
  LEVELS = %w[blocker must_fix acceptable unverified].freeze

  module_function

  def run(out_dir, base_sha:, head_sha:)
    items = []

    # 1. 锚点报告
    anchors_items = collect(items, "anchors", File.join(out_dir, "anchors_report.json"))

    # 2. docs 分批报告
    Dir.glob(File.join(out_dir, "docs_report_*.json")).sort.each do |path|
      collect(items, "docs", path)
    end

    # 3. 锚点生成/核验的非零退出
    collect_anchors_failures(items, File.join(out_dir, "anchors_extract.txt"), anchors_items)

    # 4. docs 侧执行与结构失败
    failure_log = File.join(out_dir, "docs_failures.txt")
    if File.exist?(failure_log)
      File.read(failure_log, encoding: "UTF-8").each_line do |line|
        next if line.strip.empty?

        items << item(items, "blocker", "docs: #{line.strip}")
      end
    end

    # 5. 本应产出却缺失的报告：静默缺失等于放行，必须显式记 blocker。
    #
    # 判定必须精确到「报告」而不是同前缀的任何文件（CodeRabbit）：
    # `anchors_*` 会匹配到日志 `anchors_extract.txt`，`docs_*` 会匹配到
    # `docs_failures.txt`——两者都始终存在，于是检查恒为假、永远不报警。
    # 日志不能替代报告。
    anchors_log = File.join(out_dir, "anchors_extract.txt")
    unless File.exist?(File.join(out_dir, "anchors_report.json"))
      # 生成器成功退出却无报告 = 核验被跳过；生成失败的情况另有
      # collect_anchors_failures 记账，不重复。
      if File.exist?(anchors_log) && File.read(anchors_log, encoding: "UTF-8").match?(/^extract exit=0/)
        items << item(items, "blocker", "anchors: 生成成功但无 anchors_report.json（核验被跳过）")
      elsif !File.exist?(anchors_log)
        items << item(items, "blocker", "anchors: 既无报告也无生成日志（证据缺失）")
      end
    end

    unless Dir.glob(File.join(out_dir, "docs_report_*.json")).any?
      # docs_failures.txt 非空说明失败已被单独记过；空则说明整侧缺失。
      failures = File.join(out_dir, "docs_failures.txt")
      recorded = File.exist?(failures) && !File.read(failures, encoding: "UTF-8").strip.empty?
      unless recorded
        items << item(items, "blocker", "docs: 没有任何批次报告（核验被跳过）")
      end
    end

    report = {
      "conclusion" => nil,
      "counts" => LEVELS.to_h { |level| [level, items.count { |i| i["level"] == level }] },
      "items" => items,
      "observed" => {"base" => base_sha, "head" => head_sha}
    }
    report
  end

  # 读取单份报告并归一化进 items，返回本报告贡献的条目。
  def collect(items, kind, path)
    contributed = []
    # 统一出口：既记入总表，也记入本报告的贡献列表。
    blocking = lambda do |message|
      entry = item(items, "blocker", message)
      items << entry
      contributed << entry
    end

    unless File.exist?(path)
      # docs 分批时缺某批是正常情况（批次号不连续时不存在）；锚点报告另有缺失检查。
      return contributed
    end

    raw = File.read(path, encoding: "UTF-8")
    if raw.strip.empty?
      blocking.call("#{kind}: #{File.basename(path)} 为空文件")
      return contributed
    end

    data = begin
      JSON.parse(raw)
    rescue JSON::ParserError => e
      blocking.call("#{kind}: #{File.basename(path)} 不是合法 JSON（#{e.message}）")
      return contributed
    end

    unless data.is_a?(Hash) && data["items"].is_a?(Array)
      # CLI 的错误响应形如 {"ok":false,"error":{...}}，没有 items。
      # 把它当空报告会让 400 行超限之类的失败被静默放过。
      detail = data.is_a?(Hash) && data["error"].is_a?(Hash) ? data["error"]["message"].to_s : "缺 items 数组"
      blocking.call("#{kind}: #{File.basename(path)} 结构非法：#{detail}")
      return contributed
    end

    data["items"].each_with_index do |entry, index|
      unless entry.is_a?(Hash)
        # 不能静默跳过非 Hash 条目：`{"items":[null]}` 若被跳过，
        # 唯一的结构提示就消失了，报告反而显示通过（CodeRabbit）。
        blocking.call("#{kind}: items[#{index}] 不是对象，报告结构非法")
        next
      end

      level = entry["level"].to_s
      unless LEVELS.include?(level)
        blocking.call("#{kind}: 未知 level #{level.inspect}（报告结构异常）")
        next
      end

      entry = {
        "id" => "#{kind}-#{entry["id"]}",
        "level" => level,
        "message" => "#{kind}: #{entry["message"]}",
        "evidence" => entry["evidence"]
      }
      items << entry
      contributed << entry
    end
    contributed
  end

  # 生成器/核验器的非零退出必须转成 blocker；否则「工具崩了」会被当成通过。
  # anchors_items 是锚点报告侧贡献的条目，用于判断非零退出是否由报告内
  # 阻断项预期引发——只看这一侧，docs 侧的同级条目不能掩盖 anchors 的异常。
  def collect_anchors_failures(items, log_path, anchors_items)
    return unless File.exist?(log_path)

    text = File.read(log_path, encoding: "UTF-8")
    errors = text.lines.select { |line| line.start_with?("ERROR ") }

    errors.each do |line|
      items << item(items, "blocker", "anchors: #{line.sub(/\AERROR\s*/, "").strip}")
    end

    extract_failed = text.match?(/^extract exit=[1-9]/)
    if extract_failed && errors.empty?
      items << item(items, "blocker",
        "anchors: 生成器非零退出但无可解析错误行（工具异常，须人工核查）")
    end

    # 生成器「成功退出但没产出清单」：安静跳过 verify 是典型的 fail-open。
    if text.match?(/^generator exit=\d+ 但未产出 anchors\.json/)
      items << item(items, "blocker",
        "anchors: 生成器未产出 anchors.json（工具异常，须人工核查）")
    end

    verify_failed = text.match?(/^anchors verify exit=[1-9]/)
    # 只看 **anchors 报告侧** 有无阻断项（CodeRabbit）：原判断扫的是全局
    # items，docs 侧一个 must_fix 就会掩盖 anchors 的异常退出。
    # 报告内有阻断项时非零退出是预期行为，不重复记账。
    anchors_blocking = anchors_items.any? { |i| %w[blocker must_fix].include?(i["level"]) }
    if verify_failed && !anchors_blocking
      items << item(items, "blocker",
        "anchors: 核验非零退出但报告无阻断项（报告结构异常，须人工核查）")
    end
  end

  def item(items, level, message)
    {"id" => "generated-#{items.length + 1}", "level" => level, "message" => message, "evidence" => nil}
  end

  # 结论：与 VerificationReport#conclusion 同口径。
  def conclusion(counts)
    return "打回" if counts["blocker"].to_i.positive? || counts["must_fix"].to_i.positive?
    return "有条件通过" if counts["unverified"].to_i.positive?

    "通过"
  end
end

if $PROGRAM_NAME == __FILE__
  require "optparse"

  options = {out: ".", base: "", head: ""}
  OptionParser.new do |parser|
    parser.banner = "用法：ruby tools/verify_merge_reports.rb --out DIR [--base SHA] [--head SHA]"
    parser.on("--out DIR") { |value| options[:out] = value }
    parser.on("--base SHA") { |value| options[:base] = value }
    parser.on("--head SHA") { |value| options[:head] = value }
  end.parse!(ARGV)

  report = VerifyMergeReports.run(options[:out], base_sha: options[:base], head_sha: options[:head])
  report["conclusion"] = VerifyMergeReports.conclusion(report["counts"])

  path = File.join(options[:out], "verification.json")
  File.write(path, "#{JSON.pretty_generate(report)}\n", encoding: "UTF-8")
  puts "verification.json: #{report["items"].length} items, conclusion=#{report["conclusion"]}"
end
