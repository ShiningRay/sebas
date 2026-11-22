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
    collect(items, "anchors", File.join(out_dir, "anchors_report.json"))

    # 2. docs 分批报告
    Dir.glob(File.join(out_dir, "docs_report_*.json")).sort.each do |path|
      collect(items, "docs", path)
    end

    # 3. 锚点生成/核验的非零退出
    collect_anchors_failures(items, File.join(out_dir, "anchors_extract.txt"))

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
    # 判定必须精确：某侧只有日志没有报告是正常情况（错误响应走 blocker 而非报告），
    # 不能把「该侧已有产物」也判成缺失。只有该侧**完全没有产物**时才记。
    anchors_artifacts = Dir.glob(File.join(out_dir, "anchors_*"))
    if anchors_artifacts.empty?
      items << item(items, "blocker", "anchors: 既无报告也无生成日志（证据缺失）")
    end

    docs_artifacts = Dir.glob(File.join(out_dir, "docs_*"))
    if docs_artifacts.empty?
      items << item(items, "blocker", "docs: 没有任何报告或失败记录（证据缺失）")
    end

    report = {
      "conclusion" => nil,
      "counts" => LEVELS.to_h { |level| [level, items.count { |i| i["level"] == level }] },
      "items" => items,
      "observed" => {"base" => base_sha, "head" => head_sha}
    }
    report
  end

  # 读取单份报告并归一化进 items。结构非法 → blocker（不吞错）。
  def collect(items, kind, path)
    unless File.exist?(path)
      # docs 分批时缺某批是正常情况（批次号不连续时不存在）；锚点报告另有缺失检查。
      return
    end

    raw = File.read(path, encoding: "UTF-8")
    if raw.strip.empty?
      items << item(items, "blocker", "#{kind}: #{File.basename(path)} 为空文件")
      return
    end

    data = begin
      JSON.parse(raw)
    rescue JSON::ParserError => e
      items << item(items, "blocker", "#{kind}: #{File.basename(path)} 不是合法 JSON（#{e.message}）")
      return
    end

    unless data.is_a?(Hash) && data["items"].is_a?(Array)
      # CLI 的错误响应形如 {"ok":false,"error":{...}}，没有 items。
      # 把它当空报告会让 400 行超限之类的失败被静默放过。
      detail = data.is_a?(Hash) && data["error"].is_a?(Hash) ? data["error"]["message"].to_s : "缺 items 数组"
      items << item(items, "blocker", "#{kind}: #{File.basename(path)} 结构非法：#{detail}")
      return
    end

    data["items"].each do |entry|
      next unless entry.is_a?(Hash)

      level = entry["level"].to_s
      unless LEVELS.include?(level)
        items << item(items, "blocker", "#{kind}: 未知 level #{level.inspect}（报告结构异常）")
        next
      end

      items << {
        "id" => "#{kind}-#{entry["id"]}",
        "level" => level,
        "message" => "#{kind}: #{entry["message"]}",
        "evidence" => entry["evidence"]
      }
    end
  end

  # 生成器/核验器的非零退出必须转成 blocker；否则「工具崩了」会被当成通过。
  def collect_anchors_failures(items, log_path)
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

    verify_failed = text.match?(/^anchors verify exit=[1-9]/)
    if verify_failed && items.none? { |i| %w[blocker must_fix].include?(i["level"]) }
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
