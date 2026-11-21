#!/usr/bin/env ruby
# frozen_string_literal: true

# 创建 docs/design/process/implementer-loop.md §2.2 约定的流程标签。
# 幂等：已存在的标签会被跳过。
#
# 用法：ruby tools/setup_process_labels.rb [--apply]
require "json"
require "open3"

REPO = ENV["SEBAS_REPO"] || "ShiningRay/sebas"

LABELS = [
  ["agent:in-progress", "0E8A16", "当前唯一活动工作卡；全仓最多一张"],
  ["needs:human", "D93F0B", "等待人工决策；Maintainer 处理后加 agent:resume"],
  ["agent:resume", "1D76DB", "Maintainer 已解决暂停事项并允许恢复"],
  ["metadata:invalid", "B60205", "元数据缺失或矛盾，禁止自动开工"]
].freeze

def existing
  out, err, status = Open3.capture3("gh", "label", "list", "--repo", REPO, "--limit", "200", "--json", "name")
  raise "读取标签失败：#{err.strip}" unless status.success?

  JSON.parse(out).map { |item| item["name"] }
end

apply = ARGV.include?("--apply")
present = existing
missing = LABELS.reject { |name, _, _| present.include?(name) }

if missing.empty?
  puts "全部流程标签已存在（#{LABELS.length} 个）"
  exit 0
end

missing.each do |name, color, description|
  if apply
    _out, err, status = Open3.capture3("gh", "label", "create", name,
      "--repo", REPO, "--color", color, "--description", description)
    raise "创建 #{name} 失败：#{err.strip}" unless status.success?

    puts "已创建 #{name}"
  else
    puts "将创建 #{name}（#{color}）"
  end
end

exit 0
