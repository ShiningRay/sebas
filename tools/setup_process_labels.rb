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

# gh label list 有返回上限；分批拉取直到不足一页，避免把已存在的标签误判为缺失。
PAGE_SIZE = 200

def existing
  names = []
  page = 1
  loop do
    out, err, status = Open3.capture3("gh", "label", "list", "--repo", REPO,
      "--limit", PAGE_SIZE.to_s, "--json", "name", "--search", "",
      "-q", ".[].name")
    raise "读取标签失败：#{err.strip}" unless status.success?

    batch = out.lines.map(&:strip).reject(&:empty?)
    names.concat(batch)
    break if batch.length < PAGE_SIZE

    page += 1
    raise "标签分页超过 50 页，疑似查询异常" if page > 50
  end
  names.uniq
end

# 直接查询单个标签，作为分页之外的兜底确认。
def label_exists?(name)
  _out, _err, status = Open3.capture3("gh", "label", "view", name, "--repo", REPO)
  status.success?
end

apply = ARGV.include?("--apply")
present = existing
missing = LABELS.reject { |name, _, _| present.include?(name) || label_exists?(name) }

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
