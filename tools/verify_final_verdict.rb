# frozen_string_literal: true

# 终验判定（#122 建成；#124 起随 Verifier/Reviewer 合并为终验阶段）。
#
# 只读 verification.json 出结论，不重跑核验——CI 只做确定性汇总；
#
# 真正的逐项复跑由 `sebas-process verify merge <pr> <issue> --final` 的 checker 承载。
#
# 为什么打回三类：
#   - blocker  ：Verifier 已断言阻断。
#   - must_fix ：应修项。本 workflow 没有 LLM，无法自动确认「修复是否到位」，
#                因此任一 must_fix 即打回，由 Implementer 修完后重跑。
#   - unverified 且无间接证据：与 Verifier.final_verification 同口径——
#                没有证据的未实测项不能算通过。
#
# unverified 但有 evidence（间接证据）时不算失败：那属于「有条件通过」，
# 按角色设计应交 Maintainer 裁决，不在这里阻断 PR。

require "json"

module VerifyFinalVerdict
  LEVELS = %w[blocker must_fix acceptable unverified].freeze

  module_function

  # 消费边界的结构校验（CodeRabbit）：损坏的报告不得判成「通过」。
  # 上游客（verify_merge_reports）做同类校验，但消费边界必须自证——
  # 只修上游不能代替这里的检查。
  #
  # 返回 nil 表示结构合法，否则返回问题描述（调用方按打回处理）。
  def structure_problem(report)
    return "报告不是 JSON 对象" unless report.is_a?(Hash)

    unless report["items"].is_a?(Array)
      detail = report.dig("error", "message")
      return "报告缺 items 数组#{detail ? "（#{detail}）" : ""}"
    end

    report["items"].each_with_index do |entry, index|
      return "items[#{index}] 不是对象" unless entry.is_a?(Hash)

      level = entry["level"].to_s
      return "items[#{index}] 的 level #{level.inspect} 非法" unless LEVELS.include?(level)
    end

    nil
  end

  def decide(report)
    if (problem = structure_problem(report))
      # 结构非法等同于阻断：宁可打回也不能让损坏报告显示为通过。
      return {
        "passed" => false,
        "structure_problem" => problem,
        "blockers" => [], "must_fix" => [], "no_evidence" => []
      }
    end

    items = report["items"]
    blockers = items.select { |i| i["level"] == "blocker" }
    must_fix = items.select { |i| i["level"] == "must_fix" }
    no_evidence = items.select do |i|
      i["level"] == "unverified" && i["evidence"].to_s.strip.empty?
    end

    {
      "passed" => blockers.empty? && must_fix.empty? && no_evidence.empty?,
      "structure_problem" => nil,
      "blockers" => blockers,
      "must_fix" => must_fix,
      "no_evidence" => no_evidence
    }
  end

  def render(result)
    lines = ["## 终验结论", ""]
    unless result["passed"]
      lines << "结论：**打回**"
      lines << ""
      if result["structure_problem"]
        lines << "报告结构非法：#{result["structure_problem"]}"
        lines << ""
        lines << "（无法判定核验项，按打回处理。）"
        return lines
      end

      lines << "blocker=#{result["blockers"].length} " \
        "must_fix=#{result["must_fix"].length} " \
        "无证据未实测=#{result["no_evidence"].length}"
      lines << ""
      result["blockers"].each { |i| lines << "- 阻断：#{i["message"]}" }
      result["must_fix"].each { |i| lines << "- 应修：#{i["message"]}" }
      result["no_evidence"].each { |i| lines << "- 未实测且无间接证据：#{i["message"]}" }
      return lines
    end

    lines << "结论：**通过**（无阻断、无应修、无缺证未实测项）"
    lines
  end
end

if $PROGRAM_NAME == __FILE__
  require "optparse"

  path = nil
  OptionParser.new do |parser|
    parser.banner = "用法：ruby tools/verify_final_verdict.rb <verification.json>"
  end.parse!(ARGV)
  path = ARGV.first
  abort("缺少 verification.json 路径") if path.nil?

  # 读不到 / 解析不了同样按打回处理并保持可读输出——不能让异常替我们沉默。
  result = begin
    data = JSON.parse(File.read(path, encoding: "UTF-8"))
    VerifyFinalVerdict.decide(data)
  rescue Errno::ENOENT
    {"passed" => false, "structure_problem" => "找不到报告文件 #{path}",
     "blockers" => [], "must_fix" => [], "no_evidence" => []}
  rescue JSON::ParserError => e
    {"passed" => false, "structure_problem" => "报告不是合法 JSON（#{e.message}）",
     "blockers" => [], "must_fix" => [], "no_evidence" => []}
  end

  puts VerifyFinalVerdict.render(result).join("\n")
  exit(result["passed"] ? 0 : 1)
end
