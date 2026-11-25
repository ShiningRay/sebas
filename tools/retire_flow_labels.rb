#!/usr/bin/env ruby
# frozen_string_literal: true

# 清理已废弃的流程标签：`plan` 与 `agent:in-progress`。
#
# 背景：
#   - `plan` 标签改为 milestone（是否已排期）+ Automation.kind（是否可执行）+ status（进度）。
#     milestone 为空的卡即未排期，不再需要额外标签。
#   - `agent:in-progress` 改为 issue status = In progress / In review。
#
# 只移除 issue 上的标签关联，不删除标签定义本身（可保留供历史查询）。
# 幂等：已无该标签的 issue 跳过。
#
# 用法：
#   ruby tools/retire_flow_labels.rb              # dry-run
#   ruby tools/retire_flow_labels.rb --apply
#   ruby tools/retire_flow_labels.rb --apply --label plan
require "json"
require "open3"

REPO = ENV["SEBAS_REPO"] || "ShiningRay/sebas"
APPLY = ARGV.include?("--apply")
LABELS = begin
  index = ARGV.index("--label")
  index ? [ARGV[index + 1]] : %w[plan agent:in-progress]
end

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

def issues_with(label)
  page = 1
  all = []
  loop do
    batch = gh_json("api", "repos/#{REPO}/issues?state=all&labels=#{label}&per_page=100&page=#{page}")
    break if batch.empty?

    all.concat(batch.reject { |item| item.key?("pull_request") })
    break if batch.length < 100

    page += 1
  end
  all
end

failures = []
LABELS.each do |label|
  targets = issues_with(label)
  puts "== #{label}：#{targets.length} 张 =="
  if targets.empty?
    puts "  无需处理"
    next
  end
  puts "  #{targets.map { |i| "##{i["number"]}" }.join(" ")}"

  unless APPLY
    puts "  dry-run：加 --apply 才写入"
    next
  end

  targets.each do |issue|
    number = issue["number"]
    begin
      gh!("issue", "edit", number.to_s, "--repo", REPO, "--remove-label", label)
      remaining = gh_json("api", "repos/#{REPO}/issues/#{number}")["labels"].map { |l| l["name"] }
      raise "回读仍有 #{label}" if remaining.include?(label)

      puts "  ✓ ##{number}"
    rescue StandardError => e
      failures << "##{number} #{label}：#{e.message}"
      warn "  ✗ ##{number}：#{e.message}"
    end
  end
end

if failures.empty?
  puts "\n完成"
  exit 0
else
  puts "\n#{failures.length} 项失败："
  failures.each { |line| puts "  - #{line}" }
  exit 1
end
