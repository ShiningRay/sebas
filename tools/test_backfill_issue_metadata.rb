# frozen_string_literal: true

# backfill_issue_metadata.rb 的推断规则回归。
# 脚本要写线上 issue 的 type/status，规则错了会污染整仓元数据，必须锁住。
require "minitest/autorun"
require "json"

class IssueMetadataBackfillTest < Minitest::Test
  SCRIPT = File.expand_path("backfill_issue_metadata.rb", __dir__)

  # 只加载纯函数与正则常量，不执行文件末尾的网络流程。
  def self.load_helpers
    source = File.read(SCRIPT, encoding: "UTF-8")
    constant = "MILESTONE_TITLE = #{source[/^MILESTONE_TITLE = (.+)$/, 1]}"
    methods = %w[automation_kind infer_type infer_status].map do |name|
      source[/^def #{name}\b.*?^end$/m] or raise "找不到 #{name}"
    end
    [constant] + methods
  end

  eval(load_helpers.join("\n")) # rubocop:disable Security/Eval

  def kind_body(kind)
    "```json automation\n{\"schema\":1,\"kind\":\"#{kind}\",\"order\":[1],\"depends_on\":[],\"external\":[]}\n```\n"
  end

  def test_automation_kind_reads_work_package
    assert_equal "work_package", automation_kind(kind_body("work_package"))
  end

  def test_automation_kind_returns_nil_without_block
    assert_nil automation_kind("## 目标\n没有 Automation\n")
  end

  def test_automation_kind_returns_nil_on_broken_json
    assert_nil automation_kind("```json automation\n{not json}\n```\n")
  end

  # type 按 issue 性质定：可执行卡是 Feature，父卡/人工卡/设计卡是 Task。
  def test_infer_type_work_package_is_feature
    assert_equal "Feature", infer_type({"title" => "M4.1-WP1 实现"}, "work_package")
  end

  def test_infer_type_tracking_is_task
    assert_equal "Task", infer_type({"title" => "M4.1 一期"}, "tracking")
  end

  def test_infer_type_manual_and_design_are_task
    assert_equal "Task", infer_type({"title" => "E.1-1 邮箱就绪"}, "manual")
    assert_equal "Task", infer_type({"title" => "M4x-Design-WP1 设计细化"}, "design")
  end

  # 无 Automation 的父卡（M 期编号或标题含「父卡」）算 Task，其余按 Feature 兜底。
  def test_infer_type_without_kind_uses_title_fallback
    assert_equal "Task", infer_type({"title" => "M8 父卡：渠道扩展"}, nil)
    assert_equal "Task", infer_type({"title" => "M5.4-WP1 门禁与发布"}, nil)
    assert_equal "Feature", infer_type({"title" => "登录页无法保存"}, nil)
  end

  def test_infer_status_closed_completed_is_done
    assert_equal "Done", infer_status({"state" => "CLOSED", "state_reason" => "COMPLETED", "milestone" => nil})
  end

  def test_infer_status_closed_not_planned
    assert_equal "Not planned", infer_status({"state" => "CLOSED", "state_reason" => "NOT_PLANNED", "milestone" => nil})
  end

  def test_infer_status_open_with_milestone_is_todo
    assert_equal "Todo", infer_status({"state" => "OPEN", "milestone" => {"number" => 2}})
  end

  def test_infer_status_open_without_milestone_is_backlog
    assert_equal "Backlog", infer_status({"state" => "OPEN", "milestone" => nil})
  end
end
