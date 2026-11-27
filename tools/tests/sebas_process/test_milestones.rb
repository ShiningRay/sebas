# frozen_string_literal: true

# 里程碑策略：主线/并行轨的 order 归一、非法元数据与空闲/交接判定。
# 全部基于固定 JSON 快照，不访问网络。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class MilestonePolicyTest < Minitest::Test
  include SnapshotHelpers

  def normalize(milestones)
    SebasAgents::Policy::Milestones.normalize(milestones.map { |item| SebasAgents::Model::Milestone.from_hash(item) })
  end

  def test_main_and_parallel_same_number_coexist
    items = normalize([
      {"number" => 2, "title" => "M4", "state" => "open", "order" => "4", "track" => "main", "open_issues" => 3, "description" => "order: 4
track: main
"},
      {"number" => 1, "title" => "M4x", "state" => "open", "order" => "4x", "track" => "parallel", "open_issues" => 9, "description" => "order: 4x
track: parallel
"}
    ])
    assert_equal 2, items.length
    assert_equal [:select, 2], SebasAgents::Policy::Milestones.active(items).then { |(state, item)| [state, item.number] }
  end

  def test_duplicate_main_order_is_invalid
    error = assert_raises(SebasAgents::InvalidPlan) do
      normalize([
        {"number" => 2, "title" => "a", "state" => "open", "order" => "4", "track" => "main", "open_issues" => 1, "description" => "order: 4
track: main
"},
        {"number" => 3, "title" => "b", "state" => "open", "order" => "4", "track" => "main", "open_issues" => 1, "description" => "order: 4
track: main
"}
      ])
    end
    assert_includes error.message, "重复"
  end

  def test_missing_metadata_is_invalid
    assert_raises(SebasAgents::InvalidPlan) do
      normalize([{"number" => 2, "title" => "a", "state" => "open", "description" => ""}])
    end
  end

  def test_parallel_track_does_not_participate
    items = normalize([
      {"number" => 1, "title" => "M4x", "state" => "open", "order" => "1x", "track" => "parallel", "open_issues" => 9, "description" => "order: 1x
track: parallel
"},
      {"number" => 2, "title" => "M5", "state" => "open", "order" => "5", "track" => "main", "open_issues" => 1, "description" => "order: 5
track: main
"}
    ])
    state, active = SebasAgents::Policy::Milestones.active(items)
    assert_equal :select, state
    assert_equal 2, active.number
  end

  def test_open_without_work_hands_off_release
    items = normalize([
      {"number" => 2, "title" => "M4", "state" => "open", "order" => "4", "track" => "main", "open_issues" => 0, "description" => "order: 4
track: main
"}
    ])
    assert_equal :handoff_release, SebasAgents::Policy::Milestones.active(items).first
  end

  def test_all_closed_is_idle
    items = normalize([
      {"number" => 2, "title" => "M4", "state" => "closed", "order" => "4", "track" => "main", "open_issues" => 0, "description" => "order: 4
track: main
"}
    ])
    assert_equal :idle, SebasAgents::Policy::Milestones.active(items).first
  end

  def test_non_numeric_main_order_is_invalid
    assert_raises(SebasAgents::InvalidPlan) do
      normalize([{"number" => 2, "title" => "a", "state" => "open", "order" => "4x", "track" => "main", "open_issues" => 1, "description" => "order: 4x
track: main
"}])
    end
  end
end
