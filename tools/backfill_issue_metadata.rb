#!/usr/bin/env ruby
# frozen_string_literal: true

# 一次性迁移：把 Issue Type 与 Issue Status 落到存量 issue 上。
#
# 背景（docs/design/process/triager.md §4）：
#   - type 按 issue 性质定：报 bug 的 Bug、提需求的 Feature、文档/CI/工具的 Task。
#   - plan 标签已废弃：是否已排期只看 milestone；是否已接受看 backlog 标签。
#   - 新建 issue 默认 status=Backlog；挂了 milestone 的卡应为 Todo。
#
# 规则：
#   type 为空时按 Automation.kind 推断
#     work_package → Feature；tracking / manual / design → Task
#     无 Automation 块 → 按标题前缀兜底：M?.? 父卡 → Task，其余 → Feature
#   status 为空时按 state/milestone 推断
#     closed + completed → Done；closed + not_planned → Not planned
#     open + 有 milestone → Todo；open + 无 milestone → Backlog
#   已有 type/status 的一律不改（幂等，可重复跑）。
#
# 用法：
#   ruby tools/backfill_issue_metadata.rb             # dry-run，只打印计划
#   ruby tools/backfill_issue_metadata.rb --apply     # 实际写入
#   ruby tools/backfill_issue_metadata.rb --apply --only-type
#   ruby tools/backfill_issue_metadata.rb --apply --only-status
require "json"
require "open3"

REPO = ENV["SEBAS_REPO"] || "ShiningRay/sebas"
APPLY = ARGV.include?("--apply")
ONLY_TYPE = ARGV.include?("--only-type")
ONLY_STATUS = ARGV.include?("--only-status")

def gh_json(*args)
  out, err, status = Open3.capture3("gh", *args)
  raise "gh #{args.join(" ")} 失败：#{err.strip}" unless status.success?

  out.strip.empty? ? nil : JSON.parse(out)
end

def gh!(*args)
  out, err, status = Open3.capture3("gh", *args)
  raise "gh #{args.join(" ")} 失败：#{err.strip}" unless status.success?

  out
end

def automation_kind(body)
  match = body.to_s.match(/```json automation\s*\n(.*?)```/m)
  return nil unless match

  JSON.parse(match[1])["kind"]
rescue JSON::ParserError
  nil
end

# type 推断：kind 决定性质；无 Automation 的父卡（M 期编号标题如 M5.4-WP1 / M8 父卡）算 Task。
MILESTONE_TITLE = /\AM\d+(?:x|\.\d+)?(?:[-\s:]|$)/

def infer_type(issue, kind)
  return "Feature" if kind == "work_package"
  return "Task" if %w[tracking manual design].include?(kind)
  return "Task" if issue["title"].match?(MILESTONE_TITLE) || issue["title"].include?("父卡")

  "Feature"
end

def infer_status(issue)
  if issue["state"].casecmp?("CLOSED")
    issue["state_reason"].to_s.casecmp?("NOT_PLANNED") ? "Not planned" : "Done"
  elsif issue["milestone"]
    "Todo"
  else
    "Backlog"
  end
end

def fetch_issues
  page = 1
  all = []
  loop do
    batch = gh_json("api", "repos/#{REPO}/issues?state=all&per_page=100&page=#{page}")
    break if batch.empty?

    all.concat(batch.reject { |item| item.key?("pull_request") })
    break if batch.length < 100

    page += 1
  end
  all
end

issues = fetch_issues
puts "仓库 #{REPO}：#{issues.length} 张 issue（不含 PR）"

type_plan = []
status_plan = []
issues.each do |issue|
  kind = automation_kind(issue["body"])

  unless ONLY_STATUS
    current = issue.dig("type", "name")
    if current.nil?
      type_plan << [issue["number"], infer_type(issue, kind), kind]
    end
  end

  unless ONLY_TYPE
    current = issue.dig("status", "name")
    if current.nil?
      status_plan << [issue["number"], infer_status(issue), issue["state"], !issue["milestone"].nil?]
    end
  end
end

unless ONLY_STATUS
  puts "\n== type 回填（#{type_plan.length} 张）=="
  type_plan
    .group_by { |_n, type, kind| [type, kind] }
    .sort_by { |(type, kind), _| [type.to_s, kind.to_s] }
    .each do |(type, kind), rows|
      numbers = rows.map(&:first).sort
      puts "  #{type}  kind=#{kind || "无"}  #{numbers.length} 张：#{numbers.join(" ")}"
    end
end

unless ONLY_TYPE
  puts "\n== status 回填（#{status_plan.length} 张）=="
  status_plan
    .group_by { |_n, status, _state, scheduled| [status, scheduled] }
    .sort_by { |(status, _), _| status.to_s }
    .each do |(status, scheduled), rows|
      numbers = rows.map(&:first).sort
      puts "  #{status}（#{scheduled ? "有 milestone" : "无 milestone"}）  #{numbers.length} 张：#{numbers.join(" ")}"
    end
end

unless APPLY
  puts "\n dry-run：加 --apply 才写入"
  exit 0
end

failures = []
unless ONLY_STATUS
  type_plan.each do |number, type, _kind|
    begin
      gh!("api", "-X", "PATCH", "repos/#{REPO}/issues/#{number}", "-f", "type=#{type}")
      actual = gh_json("api", "repos/#{REPO}/issues/#{number}").dig("type", "name")
      raise "回读 type=#{actual.inspect}，期望 #{type}" unless actual == type

      puts "  ✓ ##{number} type=#{type}"
    rescue StandardError => e
      failures << "##{number} type：#{e.message}"
      warn "  ✗ ##{number} type：#{e.message}"
    end
  end
end

unless ONLY_TYPE
  status_plan.each do |number, status, _state, _scheduled|
    begin
      gh!("api", "-X", "PATCH", "repos/#{REPO}/issues/#{number}", "-f", "status=#{status}")
      actual = gh_json("api", "repos/#{REPO}/issues/#{number}").dig("status", "name")
      raise "回读 status=#{actual.inspect}，期望 #{status}" unless actual == status

      puts "  ✓ ##{number} status=#{status}"
    rescue StandardError => e
      failures << "##{number} status：#{e.message}"
      warn "  ✗ ##{number} status：#{e.message}"
    end
  end
end

if failures.empty?
  puts "\n全部写入并回读确认通过"
  exit 0
else
  puts "\n#{failures.length} 项失败，需人工核对："
  failures.each { |line| puts "  - #{line}" }
  exit 1
end
