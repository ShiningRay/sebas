# frozen_string_literal: true

# Reviewer 的终验判定（#122）。
#
# 只读 verification.json 出结论，不重跑核验（与 Reviewer 的设计一致）。
#
# 为什么打回三类：
#   - blocker  ：Verifier 已断言阻断。
#   - must_fix ：应修项。本 workflow 没有 LLM，无法自动确认「修复是否到位」，
#                因此任一 must_fix 即打回，由 Implementer 修完后重跑。
#   - unverified 且无间接证据：与 Reviewer.final_verification 同口径——
#                没有证据的未实测项不能算通过。
#
# unverified 但有 evidence（间接证据）时不算失败：那属于「有条件通过」，
# 按角色设计应交 Maintainer 裁决，不在这里阻断 PR。

require "json"

module VerifyReviewerVerdict
  module_function

  def decide(report)
    items = Array(report["items"]).select { |i| i.is_a?(Hash) }
    blockers = items.select { |i| i["level"] == "blocker" }
    must_fix = items.select { |i| i["level"] == "must_fix" }
    no_evidence = items.select do |i|
      i["level"] == "unverified" && i["evidence"].to_s.strip.empty?
    end

    {
      "passed" => blockers.empty? && must_fix.empty? && no_evidence.empty?,
      "blockers" => blockers,
      "must_fix" => must_fix,
      "no_evidence" => no_evidence
    }
  end

  def render(result)
    lines = ["## Reviewer 终验", ""]
    unless result["passed"]
      lines << "结论：**打回**"
      lines << ""
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
    parser.banner = "用法：ruby tools/verify_reviewer_verdict.rb <verification.json>"
  end.parse!(ARGV)
  path = ARGV.first
  abort("缺少 verification.json 路径") if path.nil?

  data = JSON.parse(File.read(path, encoding: "UTF-8"))
  result = VerifyReviewerVerdict.decide(data)
  puts VerifyReviewerVerdict.render(result).join("\n")
  exit(result["passed"] ? 0 : 1)
end
