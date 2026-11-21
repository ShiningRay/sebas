#!/usr/bin/env ruby
# frozen_string_literal: true

# 为 M4 期工作包补齐 Automation 元数据与 GitHub 原生依赖。
# 依赖真值来自每张 issue 的「依赖」字段；本脚本只把它转成机器可读形式。
#
# 用法：ruby tools/backfill_m4_automation.rb [--apply]
# 默认 dry-run，只打印将要写入的内容。
require "json"
require "open3"

REPO = ENV["SEBAS_REPO"] || "ShiningRay/sebas"

# kind: tracking = 期父卡；work_package = 可执行工作包
# order: [期号, 阶段号, WP 号]，仅在同一 milestone 内比较
#
# 关键设计：工作包不依赖父卡。父卡是汇总卡，关闭时机在子卡之后；
# 若让 WP1 依赖父卡，就永远无法开工。期之间的门禁由子卡依赖上一期末卡表达。
PLAN = {
  9 => {kind: "tracking", order: [4, 5, 0], depends_on: []},
  4 => {kind: "work_package", order: [4, 5, 1], depends_on: []},
  5 => {kind: "work_package", order: [4, 5, 2], depends_on: [4]},
  6 => {kind: "work_package", order: [4, 5, 3], depends_on: [5]},
  7 => {kind: "work_package", order: [4, 5, 4], depends_on: [4, 5]},
  8 => {kind: "work_package", order: [4, 5, 5], depends_on: [6, 7]},

  34 => {kind: "tracking", order: [4, 0, 0], depends_on: []},
  35 => {kind: "tracking", order: [4, 1, 0], depends_on: []},
  36 => {kind: "tracking", order: [4, 2, 0], depends_on: []},
  37 => {kind: "tracking", order: [4, 3, 0], depends_on: []},
  38 => {kind: "tracking", order: [4, 4, 0], depends_on: []},

  39 => {kind: "work_package", order: [4, 0, 1], depends_on: []},
  40 => {kind: "work_package", order: [4, 0, 2], depends_on: [39]},

  # M4.1 开工条件：调度 #9 的 WP1/WP2 已合（#3 已 closed，#4 待做）
  41 => {kind: "work_package", order: [4, 1, 1], depends_on: [4]},
  42 => {kind: "work_package", order: [4, 1, 2], depends_on: [41]},
  43 => {kind: "work_package", order: [4, 1, 3], depends_on: [42]},
  44 => {kind: "work_package", order: [4, 1, 4], depends_on: [43]},
  45 => {kind: "work_package", order: [4, 1, 5], depends_on: [44]},

  46 => {kind: "work_package", order: [4, 2, 1], depends_on: [45]},
  47 => {kind: "work_package", order: [4, 2, 2], depends_on: [46]},
  48 => {kind: "work_package", order: [4, 2, 3], depends_on: [47]},
  49 => {kind: "work_package", order: [4, 2, 4], depends_on: [46]},

  50 => {kind: "work_package", order: [4, 3, 1], depends_on: [48, 49]},
  51 => {kind: "work_package", order: [4, 3, 2], depends_on: [50]},
  52 => {kind: "work_package", order: [4, 3, 3], depends_on: [50]},

  53 => {kind: "work_package", order: [4, 4, 1], depends_on: [51, 52]},
  54 => {kind: "work_package", order: [4, 4, 2], depends_on: [53]},
  55 => {kind: "work_package", order: [4, 4, 3], depends_on: [53]},
  56 => {kind: "work_package", order: [4, 4, 4], depends_on: [54, 55]}
}.freeze

FENCE = /^```json[ \t]+automation[ \t]*\r?\n.*?^```[ \t]*\r?\n?/m

def gh(*args)
  attempts = 0
  begin
    attempts += 1
    out, err, status = Open3.capture3("gh", *args)
    raise "gh #{args.join(" ")} 失败：#{err.strip}" unless status.success?

    out
  rescue RuntimeError => e
    # 瞬时网络错误（EOF / 502）重试两次；其余错误直接抛出。
    raise unless e.message.match?(/EOF|502|503|timed out/i) && attempts < 3

    sleep 2
    retry
  end
end

def fetch_issue(number)
  JSON.parse(gh("api", "repos/#{REPO}/issues/#{number}"))
end

# GitHub 依赖 API 需要 issue 的数据库 id，不是编号。
ISSUE_ID_CACHE = {}
def issue_id_for(number)
  ISSUE_ID_CACHE[number] ||= JSON.parse(gh("api", "repos/#{REPO}/issues/#{number}"))["id"]
end

def automation_block(spec)
  payload = {
    "schema" => 1,
    "kind" => spec[:kind],
    "order" => spec[:order],
    "depends_on" => spec[:depends_on],
    "external" => []
  }
  "```json automation\n#{JSON.pretty_generate(payload)}\n```\n"
end

def with_block(body, block)
  stripped = body.to_s.sub(FENCE, "")
  "#{stripped.rstrip}\n\n## Automation\n\n#{block}"
end

apply = ARGV.include?("--apply")

PLAN.each do |number, spec|
  issue = fetch_issue(number)
  if issue["state"] != "open"
    warn "跳过 ##{number}（#{issue["state"]}）"
    next
  end

  body = issue["body"].to_s
  block = automation_block(spec)
  new_body = with_block(body, block)
  existing = body.match(FENCE)&.[](0)

  puts "##{number} #{issue["title"]}"
  puts "  kind=#{spec[:kind]} order=#{spec[:order].inspect} depends_on=#{spec[:depends_on].inspect}"
  puts "  已有 automation 块，将替换" if existing

  next unless apply

  current = JSON.parse(gh("api", "repos/#{REPO}/issues/#{number}/dependencies/blocked_by"))
    .map { |item| item["number"] }.sort
  wanted = spec[:depends_on].sort
  unless current == wanted
    # GitHub 依赖有专用端点；PATCH issue 上的 blocked_by 会被静默忽略。
    (current - wanted).each do |id|
      gh("api", "-X", "DELETE", "repos/#{REPO}/issues/#{number}/dependencies/blocked_by/#{issue_id_for(id)}")
    end
    (wanted - current).each do |id|
      gh("api", "-X", "POST", "repos/#{REPO}/issues/#{number}/dependencies/blocked_by",
        "-F", "issue_id=#{issue_id_for(id)}")
    end
    puts "  依赖已更新：#{current.inspect} → #{wanted.inspect}"
  end

  temp = ".tmp-body-#{number}.md"
  File.write(temp, new_body, encoding: "UTF-8")
  gh("issue", "edit", number.to_s, "--repo", REPO, "--body-file", temp)
  File.delete(temp)
  puts "  已写入"
end

exit(0)
