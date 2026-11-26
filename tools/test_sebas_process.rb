# frozen_string_literal: true

# sebas-process 回归测试。全部基于固定 JSON 快照，不访问网络。
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "agents/lib/sebas_agents"

module SnapshotHelpers
  def automation(kind: "work_package", order: [1], depends_on: [], external: [], prose: nil)
    prose_section = prose ? "\n## 前置依赖\n\n#{prose}\n" : ""
    body = <<~MD
      ## 目标
      测试
      #{prose_section}
      ```json automation
      #{" "}
      MD
    body.sub("#{" "}\n", "") + JSON.pretty_generate(
      {
        "schema" => 1,
        "kind" => kind,
        "order" => order,
        "depends_on" => depends_on,
        "external" => external
      }
    ) + "\n```\n"
  end

  def evidence(subject:, status: "accepted", ready: nil, merged: true, untested: [],
    gate_status: nil, evidence_path: nil, source: "maintainer")
    block = {
      "schema" => 1,
      "subject" => subject,
      "status" => status,
      "source" => source,
      "source_ref" => "https://github.com/o/r/issues/1#issuecomment-1",
      "pr" => 10,
      "merge_commit" => "abc123",
      "merged_into_main" => merged,
      "checks" => "https://ci/1",
      "gate_status" => gate_status,
      "evidence_path" => evidence_path,
      "untested" => untested,
      "ready" => ready
    }
    "```json evidence\n#{JSON.pretty_generate(block)}\n```\n"
  end

  def issue(number, body: "", labels: [], milestone: 2, state: "OPEN", state_reason: nil, blocked_by: [],
    status: nil, type: nil)
    {
      "number" => number,
      "title" => "issue #{number}",
      "state" => state,
      "state_reason" => state_reason,
      "body" => body,
      "labels" => labels,
      "milestone" => milestone,
      "assignees" => [],
      "blocked_by" => blocked_by,
      "status" => status,
      "type" => type
    }
  end

  def milestone(number:, order:, track:, open_issues: 0, state: "open")
    {
      "number" => number,
      "title" => "M#{order}",
      "state" => state,
      "order" => order,
      "track" => track,
      "open_issues" => open_issues,
      "description" => "order: #{order}\ntrack: #{track}\n"
    }
  end

  def snapshot(issues:, milestones: nil, pull_requests: [], maintainers: ["ShiningRay"],
    source_authors: nil, gates: {}, externals: {}, trusted_bots: [], source_bodies: {})
    {
      "repo" => "o/r",
      "main_sha" => "deadbeef",
      "milestones" => milestones || [
        milestone(number: 2, order: "4", track: "main", open_issues: issues.length),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 5)
      ],
      "issues" => issues,
      "pull_requests" => pull_requests,
      "maintainers" => maintainers,
      "source_authors" => source_authors || {
        "https://github.com/o/r/issues/1#issuecomment-1" => "ShiningRay"
      },
      "gates" => gates,
      "externals" => externals,
      "trusted_bots" => trusted_bots,
      "source_bodies" => source_bodies
    }
  end

  def select(data, record: nil)
    SebasAgents::Policy::Selection.select_action(SebasAgents::Model::Snapshot.from_hash(data), record: record)
  end
end

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

class SelectionTest < Minitest::Test
  include SnapshotHelpers

  def test_picks_lowest_order_ready_card
    data = snapshot(issues: [
      issue(39, body: automation(order: [4, 0, 2])),
      issue(40, body: automation(order: [4, 0, 1]))
    ])
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 40, action.issue
  end

  def test_missing_automation_blocks_with_reason
    data = snapshot(issues: [issue(39, body: "无元数据")])
    action = select(data)
    assert_equal "blocked", action.action
    assert_equal 39, action.excluded.first["issue"]
    assert_includes action.excluded.first["reason"], "Automation"
  end

  def test_plan_label_without_automation_is_excluded
    data = snapshot(issues: [issue(39, labels: ["plan"], body: "计划卡")])
    action = select(data)
    assert_equal "blocked", action.action
    assert_equal 1, action.excluded.length
  end

  def test_tracking_manual_and_design_excluded
    data = snapshot(issues: [
      issue(1, body: automation(kind: "tracking")),
      issue(2, body: automation(kind: "manual")),
      issue(4, body: automation(kind: "design", order: [0])),
      issue(3, body: automation(order: [4]))
    ])
    action = select(data)
    assert_equal 3, action.issue
    reasons = action.excluded.map { |item| item["reason"] }
    assert_includes reasons, "kind=design"
  end

  # §3.2：暂停卡未放行时整轮停手，不得换卡并发
  def test_needs_human_blocks_new_work
    data = snapshot(issues: [
      issue(1, body: automation, labels: ["needs:human"]),
      issue(2, body: automation(order: [4]))
    ])
    action = select(data)
    assert_equal "needs_human", action.action
    assert_equal 1, action.issue
  end

  def test_blocked_by_conflicting_with_automation_is_invalid
    data = snapshot(issues: [
      issue(1, body: automation(depends_on: [], order: [4, 1]), blocked_by: [9]),
      issue(9, body: automation(order: [4, 2]))
    ])
    action = select(data)
    assert_equal "invalid_plan", action.action
    assert_includes action.reason, "blocked_by"
  end

  def test_completed_dependency_with_evidence_unlocks
    body = automation(depends_on: [9]) + evidence(subject: "issue:9")
    data = snapshot(issues: [
      issue(1, body: body, blocked_by: [9]),
      issue(9, body: evidence(subject: "issue:9"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 1, action.issue
  end

  def test_closed_not_planned_does_not_unlock
    data = snapshot(issues: [
      issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
      issue(9, body: evidence(subject: "issue:9"), state: "CLOSED", state_reason: "NOT_PLANNED")
    ])
    assert_equal "blocked", select(data).action
  end

  # #108 问题 2：前置已关闭时，正文依赖字段与 Automation 分叉仍要被检出。
  def test_prose_dependency_missing_from_automation_is_invalid
    body = automation(depends_on: [], prose: "WP1（#3）。")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: []),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "invalid_plan", action.action
    assert(action.reason.include?("正文依赖字段"), action.reason)
  end

  def test_automation_dependency_missing_from_prose_is_invalid
    body = automation(depends_on: [3], prose: "无。")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: [3]),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "invalid_plan", action.action
    assert(action.reason.include?("未出现在正文依赖字段"), action.reason)
  end

  def test_consistent_prose_and_automation_passes
    body = automation(depends_on: [3], prose: "WP1（#3）。")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: [3]),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "claim_issue", action.action
  end

  def test_prose_without_issue_numbers_is_not_checked
    body = automation(depends_on: [], prose: "M4.0-WP1 定稿。")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: [])
    ])
    action = select(data)
    assert_equal "claim_issue", action.action
  end

  # 卡面常写「另需外部依赖 E.5（见 #35 开工条件）」这类引用说明，
  # 其中的 #35 不是依赖，不能被当成 depends_on 缺失。
  def test_reference_only_issue_number_is_not_a_dependency
    body = automation(depends_on: [3], prose: "WP1（#3）完成；另需外部依赖 E.5（见 #35 开工条件）")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: [3]),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "claim_issue", action.action, action.reason
  end

  # CR：括号里带条件说明但仍是依赖，不能被整段剥掉。
  def test_dependency_paren_with_condition_note_is_kept
    body = automation(depends_on: [3], prose: "WP1（#3，开工条件已满足）")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: [3]),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "claim_issue", action.action, action.reason
  end

  # CR：同一行既有依赖又有引用说明时，只剥引用说明。
  def test_dependency_and_reference_on_same_line
    body = automation(depends_on: [3], prose: "WP1（#3）完成；另见 #35 开工条件")
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: [3]),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    assert_equal "claim_issue", action.action, action.reason
  end

  # 依赖节标题写成变体（如「依赖关系」）时 prose_dependencies 返回 nil，
  # 正文核对会被整段跳过。必须显式报 invalid，不能静默放过。
  def test_variant_dependency_heading_is_invalid
    body = <<~MD
      ## 目标
      测试

      ## 依赖关系

      - 前置：#3 完成

      ```json automation
      #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
         "depends_on" => [], "external" => []}.to_json}
      ```
    MD
    data = snapshot(issues: [issue(4, body: body, blocked_by: [])])
    action = select(data)
    assert_equal "invalid_plan", action.action, action.reason
    assert_includes action.reason, "依赖节标题"
    assert_includes action.reason, "依赖关系"
  end

  # 变体标题下没有 #N 引用就不构成依赖声明，不该报警。
  def test_variant_heading_without_issue_reference_is_fine
    body = <<~MD
      ## 目标
      测试

      ## 外部依赖

      - E.1#1：Slack workspace（用户侧）

      ```json automation
      #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
         "depends_on" => [], "external" => []}.to_json}
      ```
    MD
    data = snapshot(issues: [issue(4, body: body, blocked_by: [])])
    action = select(data)
    assert_equal "claim_issue", action.action, action.reason
  end

  # 论述性标题带冒号（如「依赖：背景说明」）不是依赖节标题，不能误报。
  # 该用例必须真正依赖冒号过滤：标题以「依赖」开头，去掉冒号排除后会命中正则。
  def test_descriptive_heading_with_colon_is_not_a_variant
    body = <<~MD
      ## 目标
      测试

      ### 依赖：背景说明

      见 #108。

      ```json automation
      #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
         "depends_on" => [], "external" => []}.to_json}
      ```
    MD
    data = snapshot(issues: [issue(4, body: body, blocked_by: [])])
    action = select(data)
    assert_equal "claim_issue", action.action, action.reason
  end

  # 正文里以 #N 开头的普通句子不是标题（ATX 标题要求 # 后有空白），不能误报。
  def test_issue_reference_line_is_not_treated_as_heading
    body = <<~MD
      ## 目标
      测试

      #3 的依赖
      参见 #5。

      ```json automation
      #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
         "depends_on" => [], "external" => []}.to_json}
      ```
    MD
    data = snapshot(issues: [issue(4, body: body, blocked_by: [])])
    action = select(data)
    assert_equal "claim_issue", action.action, action.reason
  end

  # CommonMark 允许 ≤3 前导空格与闭合标记；两种写法都是合法标题，必须照样检出。
  def test_indented_and_closed_variant_headings_are_detected
    ["  ## 外部依赖", "## 外部依赖 ##", "   ## 外部依赖 ##"].each do |heading|
      body = <<~MD
        ## 目标
        测试

        #{heading}

        - #3

        ```json automation
        #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
           "depends_on" => [], "external" => []}.to_json}
        ```
      MD
      data = snapshot(issues: [issue(4, body: body, blocked_by: [])])
      action = select(data)
      assert_equal "invalid_plan", action.action, "#{heading.inspect}：#{action.reason}"
      assert_includes action.reason, "外部依赖"
    end
  end

  # 代码围栏里的标题是示例内容，不是章节声明，不能据此报警。
  def test_headings_inside_code_fence_are_ignored
    body = <<~MD
      ## 目标
      测试

      ```text
      ## 依赖关系
      - #3
      ```

      ```json automation
      #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
         "depends_on" => [], "external" => []}.to_json}
      ```
    MD
    data = snapshot(issues: [issue(4, body: body, blocked_by: [])])
    action = select(data)
    assert_equal "claim_issue", action.action, action.reason
  end

  # 围栏内的变体标题配上围栏外的 #N：标题不算章节，不能报警。
  def test_variant_heading_inside_fence_with_reference_outside
    body = <<~MD
      ## 目标
      测试

      ```text
      ## 依赖关系
      ```

      - 参见 #5

      ```json automation
      #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
         "depends_on" => [], "external" => []}.to_json}
      ```
    MD
    data = snapshot(issues: [issue(4, body: body, blocked_by: [])])
    action = select(data)
    # 围栏内的标题被跳过，所以不会走到 #5 的节内扫描；结果应为正常候选。
    assert_equal "claim_issue", action.action, action.reason
  end

  # 围栏外的变体标题，其节内的 #N 只出现在子围栏里：不算依赖声明，不能报警。
  def test_variant_heading_section_reference_only_inside_fence
    body = <<~MD
      ## 目标
      测试

      ## 依赖关系

      ```text
      - #3
      ```

      ```json automation
      #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
         "depends_on" => [], "external" => []}.to_json}
      ```
    MD
    data = snapshot(issues: [issue(4, body: body, blocked_by: [])])
    action = select(data)
    assert_equal "claim_issue", action.action, action.reason
  end

  # 对照：同一变体标题下，围栏外确有 #N，就要报 invalid。
  def test_variant_heading_section_reference_outside_fence_is_invalid
    body = <<~MD
      ## 目标
      测试

      ## 依赖关系

      ```text
      - #3
      ```

      - 另见 #5

      ```json automation
      #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
         "depends_on" => [], "external" => []}.to_json}
      ```
    MD
    data = snapshot(issues: [issue(4, body: body, blocked_by: [])])
    action = select(data)
    assert_equal "invalid_plan", action.action, action.reason
    assert_includes action.reason, "依赖关系"
  end

  # 依赖节内的代码围栏里的 #N 是示例，不能算依赖声明。
  def test_issue_reference_inside_fence_within_dependency_section_is_ignored
    body = <<~MD
      ## 目标
      测试

      ## 依赖

      无前置。

      ```
      #999
      ```

      ```json automation
      #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
         "depends_on" => [], "external" => []}.to_json}
      ```
    MD
    data = snapshot(issues: [issue(4, body: body, blocked_by: [])])
    action = select(data)
    assert_equal "claim_issue", action.action, action.reason
  end

  # 围栏内的「## 依赖」不是真节：它后面围栏外的 #N 不该被当成该节的依赖。
  def test_exact_dependency_heading_inside_fence_is_not_the_section
    body = <<~MD
      ```text
      ## 依赖
      ```

      - 前置：#5 完成

      ```json automation
      #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
         "depends_on" => [], "external" => []}.to_json}
      ```
    MD
    data = snapshot(issues: [issue(4, body: body, blocked_by: [])])
    action = select(data)
    # 围栏内的标题不算依赖节，所以正文没有可对账的依赖声明，卡照常通过。
    assert_equal "claim_issue", action.action, action.reason
  end

  # 合规依赖节写成缩进或带闭合标记（CommonMark 均合法）时，仍要能正常解析。
  def test_indented_and_closed_exact_headings_are_recognized
    ["  ## 依赖", "## 依赖 ##", "   ## 依赖 ##"].each do |heading|
      body = <<~MD
        ## 目标
        测试

        #{heading}

        - 前置：#3 完成

        ```json automation
        #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
           "depends_on" => [3], "external" => []}.to_json}
        ```
      MD
      data = snapshot(issues: [
        issue(4, body: body, blocked_by: [3]),
        issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
      ])
      action = select(data)
      # 断言要能区分「解析成功」与「整段跳过」：若解析器识别不了这三个标题，
      # prose 为 nil，变体扫描也不认精确标题，会静默通过。这里必须真解析出 3。
      assert_equal "claim_issue", action.action, "#{heading.inspect}：#{action.reason}"
      refute_includes action.reason.to_s, "依赖节标题"
      # 反向验证：把正文依赖改成 #99（Automation 未声明）时必须报出来，
      # 证明该节确实被解析，而不是被跳过。
      wrong = body.sub("- 前置：#3 完成", "- 前置：#99 完成")
      wrong_data = snapshot(issues: [
        issue(5, body: wrong, blocked_by: [3]),
        issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
      ])
      wrong_action = select(wrong_data)
      assert_equal "invalid_plan", wrong_action.action, "#{heading.inspect}（#99 对照组）"
      assert_includes wrong_action.reason, "99"
    end
  end

  # 非工作包不查变体标题：直接测 Dependencies.evaluate，
  # 因为 Selection 会在依赖计算前就排除 tracking/manual/design，测不到该分支。
  def test_variant_heading_ignored_for_non_work_packages
    body = <<~MD
      ## 目标
      测试

      ## 依赖顺序

      WP4 → WP5 → WP6（见 #17）

      ```json automation
      #{{"schema" => 1, "kind" => "tracking", "order" => [4, 1],
         "depends_on" => [], "external" => []}.to_json}
      ```
    MD
    snapshot_data = SebasAgents::Model::Snapshot.from_hash(
      snapshot(issues: [issue(4, body: body, blocked_by: [])])
    )
    target = snapshot_data.issue(4)
    automation = SebasAgents::Policy::Dependencies.automation_for(target)
    result = SebasAgents::Policy::Dependencies.evaluate(target.with(automation: automation), snapshot_data)
    # tracking 不在检查范围内，不应因变体标题报 invalid。
    refute_includes result.reasons.join("；"), "依赖节标题"
  end

  # CRLF 行尾在 CommonMark 中与 LF 等价：围栏与节末判定都必须照常工作。
  def test_crlf_line_endings_are_handled
    crlf = "## 依赖\r\n\r\n```text\r\n示例\r\n```\r\n\r\n- 前置：#3 完成\r\n"
    # 围栏正常闭合，#3 被读到。
    assert_equal [3], SebasAgents::Policy::Dependencies.prose_dependencies(crlf)

    # 对照：CRLF 下的变体标题仍要报。
    variant = "## 外部依赖\r\n\r\n- #3\r\n"
    assert_equal ["外部依赖"], SebasAgents::Policy::Dependencies.mismatched_dependency_headings(variant)
  end

  # 精确标题带尾部引用（「依赖 #3」「前置依赖 #3」）不是合规依赖节，必须报。
  def test_exact_heading_with_trailing_reference_is_variant
    ["## 依赖 #3", "## 前置依赖 #3"].each do |heading|
      body = "#{heading}\n\n无。\n"
      variants = SebasAgents::Policy::Dependencies.mismatched_dependency_headings(body)
      assert_equal [heading.sub(/\A#+\s*/, "")], variants, heading
    end

    # 对照：规范的依赖节不受影响。
    ok = "## 依赖\n\n- 前置：#3 完成\n"
    assert_equal [], SebasAgents::Policy::Dependencies.mismatched_dependency_headings(ok)
    assert_equal [3], SebasAgents::Policy::Dependencies.prose_dependencies(ok)
  end

  # 变体标题尾部带 issue 引用（「外部依赖 #3」）时，分类要先剥离尾部引用。
  def test_variant_heading_with_trailing_reference_is_classified
    body = "## 外部依赖 #3\n\n无。\n"
    assert_equal ["外部依赖 #3"], SebasAgents::Policy::Dependencies.mismatched_dependency_headings(body)

    # 对照：尾部引用换成 E.1 外部编号时不算 issue 依赖，不报。
    plain = "## 外部依赖\n\n- E.1#1：Slack\n"
    assert_equal [], SebasAgents::Policy::Dependencies.mismatched_dependency_headings(plain)
  end

  # 空 ATX 标题（裸 ##）按 CommonMark 同样终止上一节。
  def test_empty_atx_heading_terminates_section
    body = <<~MD
      ## 目标
      测试

      ## 外部依赖

      无。

      ##

      验收涉及 #3

      ```json automation
      #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
         "depends_on" => [], "external" => []}.to_json}
      ```
    MD
    data = snapshot(issues: [issue(4, body: body, blocked_by: [])])
    action = select(data)
    # #3 在空标题之后的验收节里，不属于「外部依赖」节，不该报警。
    assert_equal "claim_issue", action.action, action.reason
  end

  # 变体标题行本身携带 #N 时也必须报——否则该引用被整段忽略。
  def test_variant_heading_with_inline_reference_is_invalid
    body = <<~MD
      ## 目标
      测试

      ## 依赖关系 #3

      无。

      ```json automation
      #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
         "depends_on" => [], "external" => []}.to_json}
      ```
    MD
    data = snapshot(issues: [issue(4, body: body, blocked_by: [])])
    action = select(data)
    assert_equal "invalid_plan", action.action, action.reason
    assert_includes action.reason, "依赖关系"
  end

  # CommonMark：闭合围栏长度 ≥ 开启长度、且只能有空白。
  # 断言必须区分「围栏正确闭合」与「围栏一直开着」：用 ``` 开启、
  # 正常闭合后写真实前置，若围栏没闭合该前置会读不到。
  def test_fence_close_must_be_long_enough_and_bare
    body = <<~MD
      ## 依赖

      ```
      #999
      ````

      - 前置：#3 完成

      ```json automation
      #{{"schema" => 1, "kind" => "work_package", "order" => [4, 1],
         "depends_on" => [3], "external" => []}.to_json}
      ```
    MD
    data = snapshot(issues: [
      issue(4, body: body, blocked_by: [3]),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    action = select(data)
    # ```` 是合法闭合，故 #999 被跳过、#3 被读到 → 三方一致。
    assert_equal "claim_issue", action.action, action.reason
    refute_includes action.reason.to_s, "999"

    # 对照：用 ``` 之外的 ```js 闭合（带 info string）不合规，
    # 围栏一直开着，#3 读不到 → Automation 声明了却未出现在正文。
    bad = body.sub("````", "```js")
    bad_data = snapshot(issues: [
      issue(5, body: bad, blocked_by: [3]),
      issue(3, body: evidence(subject: "issue:3"), state: "CLOSED", state_reason: "COMPLETED")
    ])
    bad_action = select(bad_data)
    assert_equal "invalid_plan", bad_action.action, bad_action.reason
  end

  # 闭合围栏长度不足（开 ```` 用 ``` 闭）在 CommonMark 里不算闭合。
  def test_short_close_does_not_close_fence
    body = "## 依赖\n\n````\n#999\n```\n\n- 前置：#3 完成\n"
    # ``` 无法闭合 ````，故 #3 也在围栏内，读不到任何依赖。
    assert_equal [], SebasAgents::Policy::Dependencies.prose_dependencies(body)
  end

  # 单行 ```x``` 是行内代码跨度，不是围栏开启；其后的真实依赖节必须仍能解析。
  def test_single_line_code_span_is_not_fence
    body = "``` 示例 ```\n\n## 依赖\n\n- 前置：#3 完成\n"
    # 若误判为围栏，`## 依赖` 与 #3 都读不到，prose 会是 []。
    assert_equal [3], SebasAgents::Policy::Dependencies.prose_dependencies(body)
  end

  def test_completed_dependency_without_evidence_blocks
    data = snapshot(issues: [
      issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
      issue(9, body: "", state: "CLOSED", state_reason: "COMPLETED")
    ])
    assert_equal "blocked", select(data).action
  end

  def test_evidence_from_non_maintainer_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9"), state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "random-user"}
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_evidence_from_trusted_bot_unlocks
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      trusted_bots: ["github-actions[bot]"]
    )
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 1, action.issue
  end

  def test_evidence_from_bot_not_in_trusted_list_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "evil-bot[bot]"},
      trusted_bots: ["github-actions[bot]"]
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_bot_cannot_forge_maintainer_source
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "maintainer"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      trusted_bots: ["github-actions[bot]"]
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_workflow_source_without_trusted_bots_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      trusted_bots: []
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_unknown_source_value_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "root"),
          state: "CLOSED", state_reason: "COMPLETED")
      ]
    )
    assert_equal "invalid_plan", select(data).action
  end

  # CR 安全项：作者合法但评论正文没有登记本结论时，不能放行。
  def test_trusted_bot_with_unrelated_comment_body_is_invalid
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => "LGTM, merging soon."},
      trusted_bots: ["github-actions[bot]"]
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_trusted_bot_with_matching_evidence_body_unlocks
    registered = evidence(subject: "issue:9", source: "workflow")
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", source: "workflow"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_authors: {"https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"},
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => registered},
      trusted_bots: ["github-actions[bot]"]
    )
    assert_equal "claim_issue", select(data).action
  end

  def test_evidence_body_with_different_subject_is_invalid
    registered = evidence(subject: "issue:99")
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9"),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => registered}
    )
    assert_equal "invalid_plan", select(data).action
  end

  # CR：issue 正文把 untested 改成 [] 不能绕过门禁——必须与登记评论一致。
  def test_evidence_untested_mismatch_is_invalid
    registered = evidence(subject: "issue:9", untested: ["真机 round-trip"])
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        # issue 正文宣称无未实测项
        issue(9, body: evidence(subject: "issue:9", untested: []),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => registered}
    )
    assert_equal "invalid_plan", select(data).action
  end

  def test_evidence_untested_match_passes
    registered = evidence(subject: "issue:9", untested: ["真机 round-trip"])
    data = snapshot(
      issues: [
        issue(1, body: automation(depends_on: [9]), blocked_by: [9]),
        issue(9, body: evidence(subject: "issue:9", untested: ["真机 round-trip"]),
          state: "CLOSED", state_reason: "COMPLETED")
      ],
      source_bodies: {"https://github.com/o/r/issues/1#issuecomment-1" => registered}
    )
    # 登记与正文一致，但仍有未实测项 → 依赖不满足（blocked，而非 invalid）。
    assert_equal "blocked", select(data).action
  end

  def test_external_not_ready_blocks
    data = snapshot(
      issues: [issue(1, body: automation(depends_on: ["external:11"], external: ["11"]), blocked_by: [])],
      externals: {"external:11" => JSON.parse(evidence(subject: "external:11", status: "ready", ready: nil).scan(/\{.*\}/m).first)}
    )
    assert_equal "blocked", select(data).action
  end

  def test_duplicate_order_is_invalid
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1])),
      issue(2, body: automation(order: [4, 1]))
    ])
    action = select(data)
    assert_equal "invalid_plan", action.action
    assert_includes action.reason, "重复"
  end

  def test_dependency_cycle_is_invalid
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1], depends_on: [2]), blocked_by: [2]),
      issue(2, body: automation(order: [4, 2], depends_on: [1]), blocked_by: [1])
    ])
    assert_equal "invalid_plan", select(data).action
  end

  def test_multiple_in_progress_is_invalid
    data = snapshot(issues: [
      issue(1, body: automation, status: "In progress"),
      issue(2, body: automation, status: "In progress")
    ])
    assert_equal "invalid_plan", select(data).action
  end

  def test_own_pull_request_resumes_before_new_card
    pr = {
      "number" => 50, "head_ref_name" => "feat/1", "state" => "OPEN",
      "merge_state_status" => "BEHIND", "checks" => [],
      "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(
      issues: [issue(1, body: automation, status: "In progress"), issue(2, body: automation(order: [4, 2]))],
      pull_requests: [pr]
    )
    action = select(data, record: {"issue" => 1, "pr" => 50, "phase" => "claimed"})
    assert_equal "resume_pr", action.action
    assert_includes action.reason, "BEHIND"
  end

  def test_pending_ci_waits
    pr = {
      "number" => 50, "state" => "OPEN", "merge_state_status" => "UNKNOWN",
      "checks" => [{"name" => "spec", "status" => "IN_PROGRESS", "conclusion" => nil}],
      "closing_issues" => [1], "review_threads" => []
    }
    data = snapshot(
      issues: [issue(1, body: automation, status: "In progress")],
      pull_requests: [pr]
    )
    assert_equal "wait", select(data, record: {"issue" => 1, "pr" => 50}).action
  end

  def test_claiming_interruption_resumes
    data = snapshot(issues: [issue(1, body: automation, status: "In progress")])
    action = select(data, record: {"issue" => 1, "phase" => "claiming"})
    assert_equal "resume_issue", action.action
    assert_includes action.reason, "claiming"
  end

  def test_paused_with_resume_returns_resume
    data = snapshot(issues: [issue(1, body: automation, labels: %w[needs:human agent:resume], status: "In progress")])
    action = select(data, record: {"issue" => 1, "phase" => "paused"})
    assert_equal "resume_issue", action.action
    assert_includes action.reason, "agent:resume"
  end

  def test_local_remote_conflict_is_invalid
    data = snapshot(issues: [issue(1, body: automation, status: "In progress")])
    assert_equal "invalid_plan", select(data, record: {"issue" => 99}).action
  end

  def test_handoff_release_when_no_open_issues
    data = snapshot(issues: [], milestones: [
      {"number" => 2, "title" => "M4", "state" => "open", "order" => "4", "track" => "main", "open_issues" => 0, "description" => "order: 4
track: main
"}
    ])
    assert_equal "handoff_release", select(data).action
  end

# 并行轨回退：主线有 open 卡但无一张就绪时，才允许并行轨补位。
  def test_falls_back_to_parallel_track_when_main_blocked
    data = snapshot(
      issues: [
        # 主线只有 tracking 卡（不可认领）→ main 评估为 blocked
        issue(1, body: automation(kind: "tracking", order: [4, 1])),
        # 并行轨有可执行卡
        issue(9, milestone: 1, body: automation(order: [4, 1]))
      ],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 1),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
      ]
    )
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 9, action.issue
    assert_equal 1, action.milestone
    assert_includes action.reason, "并行轨"
  end

  # 主线仍有就绪卡时，并行轨不得抢位。
  def test_main_ready_card_beats_parallel_track
    data = snapshot(
      issues: [
        issue(1, body: automation(order: [4, 1])),
        issue(9, milestone: 1, body: automation(order: [4, 1]))
      ],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 1),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
      ]
    )
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 1, action.issue
    assert_equal 2, action.milestone
  end

  # 主线清空要进发版门禁，不能被并行轨截走。
  def test_handoff_release_is_not_hijacked_by_parallel_track
    data = snapshot(
      issues: [issue(9, milestone: 1, body: automation(order: [4, 1]))],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 0),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
      ]
    )
    assert_equal "handoff_release", select(data).action
  end

  # 并行轨也无卡可做时，仍报主线的 blocked，不吞掉原始原因。
  def test_blocked_reported_when_parallel_track_also_empty
    data = snapshot(
      issues: [issue(1, body: automation(kind: "manual", order: [4, 1]))],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 1),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
      ]
    )
    action = select(data)
    assert_equal "blocked", action.action
    assert_equal 2, action.milestone
    assert_includes action.reason, "active 主线"
  end

  # 配置错误必须暴露，不能靠切到并行轨掩盖。
  def test_invalid_main_is_not_masked_by_parallel_track
    data = snapshot(
      issues: [
        issue(1, body: automation(order: [4, 1]), blocked_by: [99]),
        issue(9, milestone: 1, body: automation(order: [4, 1]))
      ],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 1),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
      ]
    )
    action = select(data)
    assert_equal "invalid_plan", action.action
  end

# 并行轨自己的 invalid_plan 也不能被跳过：它同样是配置错误。
def test_invalid_parallel_track_is_reported_not_skipped
  data = snapshot(
    issues: [
      issue(1, body: automation(kind: "manual", order: [4, 1])),
      # 并行轨依赖快照外的前置 → validate_graph 判非法
      issue(9, milestone: 1, body: automation(order: [4, 1]), blocked_by: [99])
    ],
    milestones: [
      milestone(number: 2, order: "4", track: "main", open_issues: 1),
      milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
    ]
  )
  action = select(data)
  assert_equal "invalid_plan", action.action
end

def test_excluded_lists_every_blocked_candidate
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1], depends_on: [9]), blocked_by: [9]),
      issue(9, body: automation(order: [4, 9]), blocked_by: [])
    ])
    action = select(data)
    assert_equal "claim_issue", action.action
    assert_equal 9, action.issue
    assert(action.excluded.any? { |item| item["issue"] == 1 })
  end

  # #114：无 milestone 的工作包卡此前完全隐形，只表现为笼统的「元数据未补齐」。
  def test_metadata_gaps_lists_work_package_without_milestone
    data = snapshot(issues: [
      # 有 plan 标签、有依赖声明，但没挂 milestone、没有 Automation
      issue(900, body: "## 前置依赖\n\nWP1（#3）。\n", labels: ["plan"], milestone: nil)
    ])
    action = select(data)
    assert_equal "blocked", action.action
    gap = action.metadata_gaps.find { |item| item["issue"] == 900 }
    refute_nil gap, "隐形卡必须出现在 metadata_gaps 中"
    assert_equal ["milestone", "automation"], gap["missing"]
  end

  def test_metadata_gaps_records_only_missing_milestone_when_automation_present
    data = snapshot(issues: [
      issue(901, body: automation(order: [4, 1]), milestone: nil)
    ])
    action = select(data)
    gap = action.metadata_gaps.find { |item| item["issue"] == 901 }
    refute_nil gap
    assert_equal ["milestone"], gap["missing"]
  end

  # 独立小修：Task + 无 milestone + work_package 块 = 正常形态，不是元数据缺口。
  def test_small_fix_without_milestone_is_not_a_metadata_gap
    data = snapshot(issues: [
      issue(903, body: automation(order: [4, 1]), milestone: nil, type: "Task")
    ])
    action = select(data)
    assert(action.metadata_gaps.none? { |item| item["issue"] == 903 })
  end

# 称小修但带前置：不算小修，缺口检查照常——它需要回到 milestone 体系。
# 主线只放 manual 卡，确保走到 blocked 分支（gaps 只在 blocked 时产出）。
  def test_small_fix_with_dependencies_is_still_a_gap
    data = snapshot(issues: [
      issue(906, body: automation(order: [4, 1], depends_on: [7]), milestone: nil, type: "Task"),
      issue(2, body: automation(kind: "manual", order: [4, 2])),
      issue(7, body: automation(kind: "manual", order: [4, 3]))
    ])
    action = select(data)
    gap = action.metadata_gaps.find { |item| item["issue"] == 906 }
    refute_nil gap
    assert_equal ["milestone"], gap["missing"]
  end

  # 同样无 milestone，但 type 不是 Task 的就不算小修，仍要报缺口。
  def test_milestone_less_feature_is_still_a_gap
    data = snapshot(issues: [
      issue(904, body: automation(order: [4, 1]), milestone: nil, type: "Feature")
    ])
    action = select(data)
    gap = action.metadata_gaps.find { |item| item["issue"] == 904 }
    refute_nil gap
    assert_equal ["milestone"], gap["missing"]
  end

  # 小修不进自动选卡：主线 blocked 时不会拿它补位，只报主线 blocked。
  def test_small_fix_is_never_auto_selected
    data = snapshot(
      issues: [
        issue(1, body: automation(kind: "manual", order: [4, 1])),
        issue(905, body: automation(order: [4, 1]), milestone: nil, type: "Task")
      ],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 1),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 0)
      ]
    )
    action = select(data)
    assert_equal "blocked", action.action
    refute_equal 905, action.issue
  end

  def test_non_work_package_without_milestone_is_not_a_gap
    # 普通过 issue（无 plan、无依赖声明、无 Automation）不应污染清单。
    data = snapshot(issues: [
      issue(902, body: "只是一条建议\n", milestone: nil)
    ])
    action = select(data)
    assert_empty action.metadata_gaps
  end

  # CR：挂在 active milestone 内但缺 Automation 的卡，也要进 metadata_gaps——
  # 它的 excluded 条目会淹没在「前置阻塞」里，单靠 reason 难以定位。
  def test_metadata_gaps_lists_milestoned_card_without_automation
    data = snapshot(issues: [
      issue(903, body: "## 前置依赖\n\nWP1（#3）。\n", blocked_by: [3])
    ])
    action = select(data)
    assert_equal "blocked", action.action
    assert(action.excluded.any? { |e| e["issue"] == 903 }, "仍应出现在 excluded")
    gap = action.metadata_gaps.find { |item| item["issue"] == 903 }
    refute_nil gap, "缺 Automation 的 milestone 卡必须进 gaps"
    assert_equal ["automation"], gap["missing"]
  end

  def test_milestoned_tracking_card_is_not_a_gap
    # tracking 卡（有 Automation、kind=tracking）不缺任何元数据，只是不参与调度。
    data = snapshot(issues: [
      issue(904, body: automation(kind: "tracking", order: [4, 0]), blocked_by: [])
    ])
    action = select(data)
    assert_empty action.metadata_gaps.select { |g| g["issue"] == 904 }
  end

  def test_design_card_is_not_a_gap_even_without_milestone
    # design 卡归 Scribe，不进 Implementer 的缺口提示。
    data = snapshot(issues: [
      issue(905, body: automation(kind: "design", order: [4, 0]), milestone: nil)
    ])
    action = select(data)
    assert_empty action.metadata_gaps.select { |g| g["issue"] == 905 }
  end

  # CR：依赖节里只有引用说明（「另见 #35」）也算工作包信号。
  def test_reference_only_dependency_section_counts_as_work_package
    body = "## 前置依赖\n\n另见 #35 开工条件。\n"
    data = snapshot(issues: [
      issue(905, body: body, milestone: nil)
    ])
    action = select(data)
    gap = action.metadata_gaps.find { |item| item["issue"] == 905 }
    refute_nil gap, "引用说明也应视为依赖节信号"
    assert_equal ["milestone", "automation"], gap["missing"]
  end

  def test_card_in_other_milestone_is_not_a_gap
    # 挂到别的 milestone 的卡不归本 active 主线调度，不能算缺口。
    data = snapshot(
      issues: [issue(906, body: "## 前置依赖\n\nWP1（#3）。\n", milestone: 1)],
      milestones: [
        milestone(number: 2, order: "4", track: "main", open_issues: 1),
        milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)
      ]
    )
    action = select(data)
    assert_empty action.metadata_gaps.select { |g| g["issue"] == 906 }
  end

  # CR：依赖节下的子标题不能提前截断节内容。
  def test_nested_heading_inside_dependency_section
    body = "## 前置依赖\n### 内部依赖\n依赖 #3\n"
    data = snapshot(issues: [issue(907, body: body, milestone: nil)])
    action = select(data)
    gap = action.metadata_gaps.find { |item| item["issue"] == 907 }
    refute_nil gap, "子标题之后的内容仍属依赖节"
    assert_equal ["milestone", "automation"], gap["missing"]
  end

  def test_sibling_heading_ends_dependency_section
    # 同级标题（## 验收）应结束依赖节；其后的 #3 不算依赖信号。
    body = "## 前置依赖\n\n无\n\n## 验收\n\n参见 #3 的说明\n"
    data = snapshot(issues: [issue(908, body: body, milestone: nil)])
    action = select(data)
    assert_empty action.metadata_gaps.select { |g| g["issue"] == 908 }
  end

  # CR：`#3` 是 issue 引用，不是一级标题；不能被当成节结束。
  def test_issue_reference_at_line_start_is_not_a_heading
    body = "## 前置依赖\n#3\n"
    data = snapshot(issues: [issue(909, body: body, milestone: nil)])
    action = select(data)
    gap = action.metadata_gaps.find { |item| item["issue"] == 909 }
    refute_nil gap, "行首 #3 是引用而非标题，依赖节不应在此结束"
  end

  def test_metadata_gaps_absent_when_claimable_card_exists
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1]), blocked_by: []),
      issue(900, body: "## 前置依赖\n\nWP1（#3）。\n", labels: ["plan"], milestone: nil)
    ])
    action = select(data)
    assert_equal "claim_issue", action.action
    # 有可认领卡时不返回 blocked，因此不产出 gaps（保持输出精简）。
    assert_empty action.metadata_gaps
  end
end

class VerifierTest < Minitest::Test
  include SnapshotHelpers

  def test_docs_reports_line_anchors_and_size
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "见 design.md:L12\n" + ("填充\n" * 410), encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_docs(["doc.md"], root: dir, max_lines: 400)
      refute report.pass?
      assert report.must_fix_items.any? { |item| item.message.include?("行号锚") }
      assert report.must_fix_items.any? { |item| item.message.include?("超过") }
    end
  end

  # #124：可复跑的 must_fix 必须带 evidence 命令，checker 才能就地复跑收口。
  def test_docs_must_fix_items_carry_rerunnable_evidence
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "见 design.md:L12\n" + ("填充\n" * 410), encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_docs(["doc.md"], root: dir, max_lines: 400)

      size_item = report.must_fix_items.find { |item| item.message.include?("超过") }
      refute_nil size_item&.evidence, "行数超限条目应带可复跑命令"
      require "shellwords"
      assert_equal SebasAgents::Verifier::RERUN_LINE_COUNT % [400, Shellwords.escape("doc.md")], size_item.evidence

      anchor_item = report.must_fix_items.find { |item| item.message.include?("行号锚") }
      refute_nil anchor_item&.evidence, "锚点存在条目应带可复跑命令"
      assert_equal SebasAgents::Verifier::RERUN_DOCS_CHECK % Shellwords.escape("doc.md"), anchor_item.evidence

      # 行数命令真实复跑：修复后（行数降回上限内）应通过。
      checker = SebasAgents::VerifyChecks
      File.write(path, "见 design.md\n", encoding: "UTF-8")
      shrunk = SebasAgents::Verifier.verify_docs(["doc.md"], root: dir, max_lines: 400)
      assert shrunk.pass?, "行数修复后应无 must_fix"
      result = checker.rerun(size_item, {}, root: dir)
      assert result[:passed], "行数 evidence 命令对修复后的文件应通过：#{result[:reason]}"
    end
  end

  # CodeRabbit：路径含空格时必须整体作为一个参数被 checker 解析。
  def test_rerun_command_escapes_paths_with_spaces
    Dir.mktmpdir do |dir|
      tricky = File.join(dir, "guide notes.md")
      File.write(tricky, "填充\n" * 401, encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_docs(["guide notes.md"], root: dir, max_lines: 400)
      item = report.must_fix_items.find { |i| i.message.include?("超过") }
      refute_nil item&.evidence
      require "shellwords"
      assert_includes item.evidence, Shellwords.escape("guide notes.md")

      # 同时放一个更短的同前缀文件：不转义时命令会读错对象并误判通过。
      File.write(File.join(dir, "guide"), "一行\n", encoding: "UTF-8")
      result = SebasAgents::VerifyChecks.rerun(item, {}, root: dir)
      refute result[:passed], "含空格路径必须整体复跑且仍失败：#{result[:reason]}"
    end
  end

  # 存档目录的行号锚是 acceptable，不参与终验，不带 evidence。
  def test_archive_anchor_item_has_no_evidence
    Dir.mktmpdir do |dir|
      path = File.join(dir, "docs/design/review/x.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "见 design.md:L12\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_docs(["docs/design/review/x.md"], root: dir)
      assert report.acceptable_items.first.evidence.nil?
    end
  end

  def test_archive_line_anchor_is_acceptable
    Dir.mktmpdir do |dir|
      path = File.join(dir, "docs/design/review/x.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "见 design.md:L12\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_docs(["docs/design/review/x.md"], root: dir)
      assert report.pass?
      assert_equal 1, report.acceptable_items.length
    end
  end

  def test_missing_file_blocks
    Dir.mktmpdir do |dir|
      report = SebasAgents::Verifier.verify_docs(["missing.md"], root: dir)
      assert_equal 1, report.blockers.length
    end
  end

  def test_code_anchor_mismatch
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "x.cr"), "真实内容\n", encoding: "UTF-8")
      report = SebasAgents::Verifier.verify_code_anchors(
        [{"file" => "src/x.cr", "line" => 1, "content" => "文档声称"}], root: dir
      )
      assert_equal 1, report.must_fix_items.length
    end
  end

  def test_verify_merge_requires_completed_issue
    data = snapshot(
      issues: [issue(39, body: automation, state: "CLOSED", state_reason: "NOT_PLANNED")],
      pull_requests: [{"number" => 10, "state" => "MERGED", "closing_issues" => [39]}]
    )
    report = SebasAgents::Verifier.verify_merge(10, 39, SebasAgents::Model::Snapshot.from_hash(data))
    refute report.pass?
  end

  # --- 合并前自检（--pre）---

  def pre_data(issue_body:, pr_extra: {}, issue_state: "OPEN")
    snapshot(
      issues: [issue(39, body: issue_body, state: issue_state)],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}],
        "review_threads" => []
      }.merge(pr_extra)],
      trusted_bots: ["github-actions[bot]"],
      source_authors: {
        "https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"
      },
      source_bodies: {
        "https://github.com/o/r/issues/1#issuecomment-1" => evidence(
          subject: "issue:39", merged: false, source: "workflow"
        )
      }
    )
  end

  def run_pre(data)
    SebasAgents::Verifier.verify_merge(
      10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true
    )
  end

  # 两阶段登记的合并前块：merged_into_main=false 且无 merge_commit，应通过。
  def test_pre_passes_with_two_phase_block
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    report = run_pre(pre_data(issue_body: body))
    assert report.pass?, "合并前块应通过，实际 blocked: #{report.blockers.map(&:message)}"
  end

  # 未合并却声称 merged_into_main=true：伪造，必须阻断。
  def test_pre_blocks_when_block_claims_merged
    body = automation + evidence(subject: "issue:39", merged: true, source: "workflow")
    report = run_pre(pre_data(issue_body: body))
    refute report.pass?
    messages = report.blockers.map(&:message).join("\n")
    assert_includes messages, "声称 merged_into_main=true"
  end

  def test_pre_blocks_without_evidence
    report = run_pre(pre_data(issue_body: automation))
    refute report.pass?
    assert(report.blockers.map(&:message).any? { |m| m.include?("缺 Evidence") })
  end

  def test_pre_blocks_on_unresolved_thread
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    data = pre_data(issue_body: body, pr_extra: {"review_threads" => [{"isResolved" => false}]})
    report = run_pre(data)
    refute report.pass?
    assert(report.blockers.map(&:message).any? { |m| m.include?("未解决 review thread") })
  end

  # 空 checks 不能算「全绿」。
  def test_pre_blocks_on_empty_checks
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    data = pre_data(issue_body: body, pr_extra: {"checks" => []})
    report = run_pre(data)
    refute report.pass?
    assert(report.blockers.map(&:message).any? { |m| m.include?("没有任何 CI 检查记录") })
  end
end

# #124：Reviewer 并入 Verifier（角色 7→6）。终验 checker 必填且真实复跑，
# 不再存在「自报已修复 = 有条件通过」的通路。
class FinalVerificationTest < Minitest::Test
  # 只根据 fix 是否命中返回结果，用于测 fixes 键匹配本身；
  # checker 的重执行行为由 VerifyChecksTest 覆盖。
  HIT = ->(_item, fix) { fix.is_a?(Hash) ? {passed: true, reason: "命中"} : {passed: false, reason: "未命中"} }

  def verification_with(items)
    report = SebasAgents::VerificationReport.new
    items.each do |level, message|
      report.public_send(level, message)
    end
    report
  end

  def final(report, fixes)
    SebasAgents::Verifier.final_verification(report, fixes, checker: HIT)
  end

  def test_unresolved_must_fix_blocks
    report = verification_with([["must_fix", "锚点不符"]])
    refute final(report, {}).pass?
    assert_equal "打回", final(report, {}).conclusion
  end

  def test_verifier_blocker_propagates
    report = verification_with([["blocker", "缺文件"]])
    assert_equal "打回", final(report, {}).conclusion
  end

  # #109：fixes 用条目自身 id 也要能匹配，不能只认 level 自编号。
  def test_fixes_keyed_by_item_id_matches
    report = SebasAgents::VerificationReport.new
    report.must_fix("锚点不符", id: "g")
    fixes = {"g" => {"passed" => true, "commit" => "abc"}}
    assert final(report, fixes).pass?
  end

  def test_item_id_kept_in_report
    report = SebasAgents::VerificationReport.new
    report.must_fix("锚点不符", id: "r2-1")
    assert_equal "r2-1", report.items.first.id
  end

  def test_auto_id_is_per_level
    report = SebasAgents::VerificationReport.new
    report.must_fix("a")
    report.acceptable("b")
    report.must_fix("c")
    assert_equal %w[must_fix-1 acceptable-1 must_fix-2], report.items.map(&:id)
  end

  # CR：显式 id 与生成的 fallback id 不得碰撞。
  def test_explicit_id_does_not_collide_with_generated
    report = SebasAgents::VerificationReport.new
    report.must_fix("a")
    report.must_fix("b", id: "must_fix-2")
    report.must_fix("c")
    assert_equal %w[must_fix-1 must_fix-2 must_fix-3], report.items.map(&:id)
    assert_equal 3, report.items.map(&:id).uniq.length
  end

  def test_duplicate_explicit_id_is_rejected
    report = SebasAgents::VerificationReport.new
    report.must_fix("a", id: "g")
    assert_raises(ArgumentError) { report.must_fix("b", id: "g") }
  end

  # CR：positional fallback 按 level 内序号，不由 id 后缀推断。
  def test_positional_fallback_is_not_derived_from_id_suffix
    report = SebasAgents::VerificationReport.new
    report.must_fix("a", id: "r2-1")
    report.must_fix("b", id: "r3-1")
    fixes = {"must_fix-1" => {"passed" => true, "commit" => "aaa"}}
    # 只有第 1 项被覆盖，第 2 项必须仍算未修复。
    assert_equal "打回", final(report, fixes).conclusion
  end

  # CR：level-only 简写只在同 level 唯一时生效。
  def test_level_only_fix_requires_unique_item
    two = SebasAgents::VerificationReport.new
    two.must_fix("a")
    two.must_fix("b")
    fixes = {"must_fix" => {"passed" => true, "commit" => "aaa"}}
    assert_equal "打回", final(two, fixes).conclusion

    one = SebasAgents::VerificationReport.new
    one.must_fix("a")
    assert final(one, fixes).pass?
  end

  # CR：位置键不能命中另一条目的显式 id，否则一条 fix 满足两项。
  def test_positional_key_does_not_shadow_other_item_explicit_id
    report = SebasAgents::VerificationReport.new
    report.must_fix("a", id: "must_fix-2")   # 显式 id 恰好等于第二项的位置键
    report.must_fix("b", id: "g")
    fixes = {"must_fix-2" => {"passed" => true, "commit" => "aaa"}}
    # 第 1 项按显式 id 命中；第 2 项的位置键 must_fix-2 被占用，不得复用 → 仍算未修复。
    assert_equal "打回", final(report, fixes).conclusion
  end

  # CR：level-only 简写同样不能命中另一条目的显式 id。
  def test_level_only_key_does_not_shadow_other_item_explicit_id
    report = SebasAgents::VerificationReport.new
    report.must_fix("a", id: "acceptable")
    report.acceptable("b", id: "g")
    fixes = {"acceptable" => {"passed" => true, "commit" => "abc", "reason_still_valid" => true}}
    # "acceptable" 是第 1 项的显式 id，第 2 项不得再借它过关。
    assert_equal "打回", final(report, fixes).conclusion
  end

  # #124：自报修复不再构成有条件通过——checker 判失败时结论必须是打回。
  def test_self_reported_fix_with_failing_checker_is_rejected
    report = SebasAgents::VerificationReport.new
    report.must_fix("锚点不符", evidence: "ruby -e \"exit 1\"")
    fixes = {"must_fix-1" => {"passed" => true, "commit" => "abc"}}
    checker = ->(item, fix) { SebasAgents::VerifyChecks.rerun(item, fix, root: Dir.pwd) }
    result = SebasAgents::Verifier.final_verification(report, fixes, checker: checker)
    refute result.pass?, "自报 passed:true 但复跑失败必须打回"
    assert_equal "打回", result.conclusion
  end

  # #124：checker 不可省——省略（生产路径旧调用形态）必须显式失败，不得静默降级。
  def test_checker_is_required
    report = verification_with([["must_fix", "锚点不符"]])
    assert_raises(ArgumentError) do
      SebasAgents::Verifier.final_verification(report, {})
    end
  end
end

class VerifyChecksTest < Minitest::Test
  def item_with(evidence)
    report = SebasAgents::VerificationReport.new
    report.must_fix("占位", evidence: evidence)
    report.must_fix_items.first
  end

  def test_reruns_command_and_passes_on_success
    result = SebasAgents::VerifyChecks.rerun(item_with("ruby -e \"exit 0\""), {})
    assert result[:passed], result[:reason].to_s
  end

  # 验收用例：fixes 写 passed:true 但实际检查失败 → 必须打回。
  def test_reruns_command_and_fails_on_failure_despite_self_report
    result = SebasAgents::VerifyChecks.rerun(item_with("ruby -e \"exit 1\""), {"passed" => true, "commit" => "abc"})
    refute result[:passed], "自报 passed:true 不能骗过 checker"
    assert_includes result[:reason].to_s, "复跑失败"
  end

  def test_empty_evidence_rejects
    result = SebasAgents::VerifyChecks.rerun(item_with(""), {"passed" => true})
    refute result[:passed]
    assert_equal "无可复跑检查", result[:reason]
  end

  def test_non_whitelisted_bin_rejects
    result = SebasAgents::VerifyChecks.rerun(item_with("curl http://example.com"), {})
    refute result[:passed]
    assert_match(/白名单/, result[:reason].to_s)
  end

  def test_git_write_subcommand_rejects
    result = SebasAgents::VerifyChecks.rerun(item_with("git push origin main"), {})
    refute result[:passed]
    assert_match(/只读/, result[:reason].to_s)
  end

  # CodeRabbit：config/remote/symbolic-ref 有写形态且无法按参数区分读写，直接排除。
  # 断言 allowed? 本身（不真跑），否则白名单若回归放行，
  # git 自身的执行失败也会让 rerun 返回 passed:false，测试区分不出拒绝分支。
  def test_git_writable_read_listed_subcommands_reject
    require "shellwords"
    %w[config remote symbolic-ref].each do |subcommand|
      reason = SebasAgents::VerifyChecks.allowed?(Shellwords.split("git #{subcommand} HEAD"))
      refute_equal true, reason, "git #{subcommand} 不应进入白名单：#{reason.inspect}"
    end
  end

  # gh 白名单判定不真跑（不依赖网络）：只测 allowed? 本身。
  def test_gh_view_is_allowed_but_edit_is_not
    require "shellwords"
    assert_equal true, SebasAgents::VerifyChecks.allowed?(Shellwords.split("gh pr view 1 --repo a/b"))
    refute_equal true, SebasAgents::VerifyChecks.allowed?(Shellwords.split("gh pr edit 1 --repo a/b"))
  end

  # 不经 shell：`;` 后的片段不会成为第二条命令；解析后仍受白名单约束。
  def test_shell_metacharacters_do_not_create_second_command
    require "shellwords"
    argv = SebasAgents::VerifyChecks.parse("crystal spec; rm -rf /")
    assert_equal ["crystal", "spec;", "rm", "-rf", "/"], argv
    # 以 argv 语义执行 crystal 时，"spec;" 只会作为非法参数，rm 不会被调用。
  end
end

# #109：叙述式 verdict 与 level 词汇统一由 VERDICTS 收口。
class VerdictMappingTest < Minitest::Test
  def test_chinese_verdicts_map_to_levels
    expected = {
      "阻断" => "blocker",
      "应修" => "must_fix",
      "可留" => "acceptable",
      "未实测" => "unverified",
      "通过" => "ok"
    }
    expected.each do |verdict, level|
      assert_equal level, SebasAgents::VerificationReport::VERDICTS.fetch(verdict), "映射 #{verdict}"
    end
  end

  def test_english_levels_pass_through
    %w[blocker must_fix acceptable unverified ok pass].each do |level|
      refute_nil SebasAgents::VerificationReport::VERDICTS[level], "缺少 #{level}"
    end
  end
end

class ReleaseTest < Minitest::Test
  def test_fix_only_bumps_patch
    plan = SebasAgents::Release.plan(latest_tag: "v0.1.0", subjects: ["fix(a): b", "docs: c"])
    assert_equal "patch", plan["action"]
    assert_equal "0.1.1", plan["next_version"]
  end

  def test_feat_blocks_patch
    plan = SebasAgents::Release.plan(latest_tag: "v0.1.0", subjects: ["fix(a): b", "feat: d"])
    assert_equal "skip", plan["action"]
  end

  def test_no_fix_is_noop
    plan = SebasAgents::Release.plan(latest_tag: "v0.1.0", subjects: ["docs: c"])
    assert_equal "noop", plan["action"]
  end

  def test_scoped_fix_matches
    plan = SebasAgents::Release.plan(latest_tag: "v1.2.9", subjects: ["fix(orchestration): x"])
    assert_equal "1.2.10", plan["next_version"]
  end
end

class CliTest < Minitest::Test
  include SnapshotHelpers

  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = SebasAgents::CLI.new(out: out, err: err).run(argv)
    [status, out.string, err.string]
  end

  # #124：终验读阶段一的 verification.json，不现场生成报告。
  def write_report(dir, items)
    path = File.join(dir, "verification.json")
    File.write(path, JSON.generate({"items" => items}), encoding: "UTF-8")
    path
  end

  def write_fixes(dir, data)
    path = File.join(dir, "fixes.json")
    File.write(path, JSON.generate(data), encoding: "UTF-8")
    path
  end

  # CodeRabbit：前阶段报告里的失败命令必须导致打回（不能借当场全绿蒙混）。
  def test_final_reads_phase_one_report_and_reruns
    Dir.mktmpdir do |dir|
      report_path = write_report(dir, [
        {"id" => "m", "level" => "must_fix", "message" => "锚点不符", "evidence" => "ruby -e \"exit 1\""}
      ])
      fixes_path = write_fixes(dir, {"m" => {"passed" => true, "commit" => "abc"}})
      status, out, = run_cli(["verify", "merge", "10", "39", "--final", "--report", report_path, "--fixes", fixes_path])
      assert_equal 1, status
      data = JSON.parse(out)
      assert_equal "打回", data["conclusion"]
      assert_equal 10, data["pr"], "终验输出应带 pr 可追溯"
    end
  end

  # CodeRabbit：带间接证据的未实测项保留「有条件通过」语义。
  def test_final_conditional_pass_with_indirect_evidence
    Dir.mktmpdir do |dir|
      report_path = write_report(dir, [
        {"id" => "u", "level" => "unverified", "message" => "CI 未跑", "evidence" => "main 上的 run 45004530157 已成功"}
      ])
      fixes_path = write_fixes(dir, {})
      status, out, = run_cli(["verify", "merge", "10", "39", "--final", "--report", report_path, "--fixes", fixes_path])
      assert_equal 0, status
      assert_equal "有条件通过", JSON.parse(out)["conclusion"]
    end
  end

  # #124：终验缺 --report 或 --fixes 在解析阶段 fail-fast。
  def test_final_requires_report_and_fixes
    Dir.mktmpdir do |dir|
      report_path = write_report(dir, [])
      status, out, = run_cli(["verify", "merge", "1", "1", "--final", "--report", report_path])
      assert_equal 2, status
      assert_includes out, "--report"
    end
  end

  def test_unknown_command_returns_usage
    status, out, = run_cli(["nope"])
    assert_equal 2, status
    assert_includes out, "usage_error"
  end

  def test_roles_lists_all
    status, out, = run_cli(["roles"])
    assert_equal 0, status
    assert_includes out, "release-manager"
  end

  def test_role_prompt_uses_real_commands
    status, out, = run_cli(%w[roles implementer --json])
    assert_equal 0, status
    documented = JSON.parse(out)["commands"]
    help_out = StringIO.new
    SebasAgents::CLI.new(out: help_out, err: StringIO.new).run(["help"])
    documented.each do |command|
      subcommand = command.split[2]
      assert_includes help_out.string, subcommand
    end
  end

    def test_oneline_is_single_line_for_every_role
    %w[implementer verifier triager scribe release-manager maintainer].each do |role|
      status, out, = run_cli(["roles", role, "--one-line"])
      assert_equal 0, status, role
      assert_equal 1, out.lines.length, "#{role} 的一句话必须是一行"
      assert_includes out, "sebas"
    end
  end

  def test_oneline_all_roles
    status, out, = run_cli(%w[roles --one-line])
    assert_equal 0, status
    assert_equal SebasAgents::RolePrompts::ROLES.length, out.lines.length
    assert_includes out, "Implementer"
    assert_includes out, "Release Manager"
  end

  def test_oneline_names_the_first_command
    status, out, = run_cli(%w[roles implementer --one-line])
    assert_equal 0, status
    assert_includes out, "ruby tools/sebas-process next"
    assert_includes out, "verify merge"
    assert_includes out, "禁 force-push"
  end

  def test_role_prompt_is_plain_text_ready_to_paste
    %w[implementer verifier triager scribe release-manager maintainer].each do |role|
      status, out, = run_cli(["roles", role, "--prompt-only"])
      assert_equal 0, status, role
      assert_includes out, "角色：sebas #{role}"
      assert_includes out, "权限边界"
      assert_includes out, "第一步"
      assert_includes out, "停止条件"
      assert_includes out, "退出码"
      refute out.start_with?("{"), "prompt-only 不应输出 JSON"
    end
  end

  def role_display(role)
    role.split("-").map(&:capitalize).join(" ")
  end

  def test_role_prompt_forbids_writes_for_read_only_roles
    %w[verifier].each do |role|
      _status, out, = run_cli(["roles", role, "--prompt-only"])
      assert_includes out, "只读"
      assert_includes out, "禁止："
    end
  end

  def test_prompt_only_requires_role
    status, out, = run_cli(%w[roles --prompt-only])
    assert_equal 2, status
    assert_includes out, "usage_error"
  end

  def test_roles_without_role_lists_all
    status, out, = run_cli(["roles"])
    assert_equal 0, status
    payload = JSON.parse(out)["roles"]
    assert_equal SebasAgents::RolePrompts::ROLES.sort, payload.keys.sort
  end

  def test_triage_with_verdict_produces_actions
    data = snapshot(issues: [issue(7, body: "bug 描述", labels: [])])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      verdict = File.join(dir, "v.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      File.write(verdict, JSON.generate({"decision" => "bug-confirmed", "body" => "复现步骤"}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "7", "--snapshot", snap, "--verdict", verdict])
      assert_equal 0, status
      payload = JSON.parse(out)
      assert_equal "bug-confirmed", payload["decision"]
      assert(payload["actions"].any? { |action| action["name"] == "bug" })
    end
  end

  def test_triage_without_verdict_asks_model
    data = snapshot(issues: [issue(7, body: "bug 描述")])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "7", "--snapshot", snap])
      assert_equal 1, status
      assert_equal "needs-model-verdict", JSON.parse(out)["decision"]
    end
  end

  def test_triage_proposal_needs_design_does_not_assign_or_schedule
    data = snapshot(issues: [issue(8, labels: ["proposal", "needs-triage"])])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      verdict = File.join(dir, "v.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      File.write(verdict, JSON.generate({"decision" => "needs-design", "body" => "待确认兼容性"}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 0, status
      actions = JSON.parse(out)["actions"]
      assert(actions.any? { |action| action["action"] == "add_label" && action["name"] == "proposal:needs-design" })
      assert(actions.any? { |action| action["action"] == "set_type" && action["type"] == "Proposal" })
      refute(actions.any? { |action| %w[add_assignee suggest_milestone close].include?(action["action"]) })
    end
  end

# 存量卡迁移期：type=Proposal 但标签已清，仍须走 Proposal 流程。
def test_proposal_detected_by_type_without_label
  data = snapshot(issues: [issue(8, labels: ["needs-triage"], type: "Proposal")])
  Dir.mktmpdir do |dir|
    snap = File.join(dir, "s.json")
    verdict = File.join(dir, "v.json")
    File.write(snap, JSON.generate(data), encoding: "UTF-8")
    File.write(verdict, JSON.generate({"decision" => "needs-design", "body" => "待确认"}), encoding: "UTF-8")
    status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
    assert_equal 0, status
    assert_includes out, "proposal:needs-design"
  end
end

# Proposal 不能走 accepted：那条路径会加 enhancement 并指派，语义不对。
def test_accepted_rejects_proposal_type
  data = snapshot(issues: [issue(8, labels: ["proposal"], type: "Proposal")])
  Dir.mktmpdir do |dir|
    snap = File.join(dir, "s.json")
    verdict = File.join(dir, "v.json")
    File.write(snap, JSON.generate(data), encoding: "UTF-8")
    File.write(verdict, JSON.generate({"decision" => "accepted"}), encoding: "UTF-8")
    status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
    assert_equal 1, status
    assert_includes out, "accepted-design"
  end
end

# 已是 Proposal 的卡不再重复写 type（避免无谓 API 调用）。
def test_proposal_plan_skips_redundant_set_type
  data = snapshot(issues: [issue(8, labels: ["proposal"], type: "Proposal")])
  Dir.mktmpdir do |dir|
    snap = File.join(dir, "s.json")
    verdict = File.join(dir, "v.json")
    File.write(snap, JSON.generate(data), encoding: "UTF-8")
    File.write(verdict, JSON.generate({"decision" => "needs-design", "body" => "待确认"}), encoding: "UTF-8")
    status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
    assert_equal 0, status
    actions = JSON.parse(out)["actions"]
    refute(actions.any? { |action| action["action"] == "set_type" })
  end
end

# 选卡排除不能只认标签：type=Proposal 的卡即使带 work_package 块也不得进候选。
def test_selection_excludes_type_proposal_without_label
  data = snapshot(issues: [
    issue(1, labels: [], type: "Proposal", body: automation(order: [4, 1])),
    issue(2, labels: [], body: automation(order: [4, 2]))
  ])
  action = select(data)
  assert_equal "claim_issue", action.action
  assert_equal 2, action.issue
  assert(action.excluded.any? { |item| item["issue"] == 1 && item["reason"].include?("proposal") })
end

  def proposal_verdict(data, dir, decision: "accepted-design", url: nil)
    url ||= "https://github.com/o/r/issues/8#issuecomment-123"
    match = SebasAgents::Triager::DECISION_URL.match(url)
    parent = if match[:kind] == "pull"
      "https://api.github.com/repos/o/r/pulls/#{match[:number]}"
    else
      "https://api.github.com/repos/o/r/issues/#{match[:number]}"
    end
    data["proposal_evidence"] ||= {}
    data["proposal_evidence"][url] = {
      "author" => "ShiningRay",
      "body" => "<!-- proposal-verdict: #{decision} -->\n理由：符合设计边界。",
      "parent" => parent
    }
    snap = File.join(dir, "s.json")
    verdict = File.join(dir, "v.json")
    File.write(snap, JSON.generate(data), encoding: "UTF-8")
    File.write(verdict, JSON.generate({
      "decision" => decision,
      "body" => "Maintainer 已裁决；排期另议。",
      "maintainer_decision_url" => url
    }), encoding: "UTF-8")
    [snap, verdict, url]
  end

# 反馈给 Maintainer 的问题要在评论里渲染成可勾选清单（GitHub 渲染 issue 评论支持任务列表）。
def test_triage_renders_checkbox_options_for_maintainer_questions
  verdict = {
    "decision" => "needs-design",
    "body" => "有两处取舍要定。",
    "questions" => [
      {"q" => "租约凭据放哪", "why" => "影响跨机器与安全边界。",
       "options" => ["正文块", "协调评论", "仅本地记录与标签"], "recommend" => 2}
    ]
  }
  issue = SebasAgents::Model::Issue.from_hash(
    {"number" => 190, "title" => "x", "state" => "OPEN", "body" => "", "labels" => ["proposal"]}
  )
  comment = SebasAgents::Triager.comment_for("needs-design", verdict)
  assert_includes comment, "### 待决问题（请勾选）"
  assert_includes comment, "- [ ] **A** 正文块"
  assert_includes comment, "- [ ] **B** 协调评论"
  assert_includes comment, "- [ ] **C** 仅本地记录与标签（推荐）"
  # 勾选只改评论、工具读不到，这一点必须写明，否则会以为勾了就生效。
  assert_includes comment, "勾选只改这条评论，工具读不到"
end

# 没有 questions 时不应凭空多出一个小节。
def test_triage_omits_questions_section_when_absent
  issue = SebasAgents::Model::Issue.from_hash(
    {"number" => 1, "title" => "x", "state" => "OPEN", "body" => "", "labels" => []}
  )
  comment = SebasAgents::Triager.comment_for("needs-info", {"body" => "缺复现步骤"})
  refute_includes comment, "待决问题"
  assert_includes comment, "缺复现步骤"
end

def triage_comment(verdict)
  issue = SebasAgents::Model::Issue.from_hash(
    {"number" => 2, "title" => "x", "state" => "OPEN", "body" => "", "labels" => ["proposal"]}
  )
  SebasAgents::Triager.comment_for(verdict["decision"], verdict)
end

# recommend 越界、负数、非整数（含字符串数字与浮点）都不得渲染推荐标记。
def test_triage_ignores_invalid_recommend_index
  [5, -1, "1", 1.0, true].each do |bad|
    verdict = {
      "decision" => "needs-design", "body" => "x",
      "questions" => [{"q" => "选哪个", "options" => ["甲", "乙"], "recommend" => bad}]
    }
    comment = triage_comment(verdict)
    refute_includes comment, "（推荐）", "recommend=#{bad.inspect} 不应产生推荐标记"
  end
end

# 过滤空项后编号按显示顺序重排，recommend 仍绑定原始选项。
def test_triage_keeps_recommend_bound_to_original_option
  verdict = {
    "decision" => "needs-design", "body" => "x",
    "questions" => [{"q" => "选哪个", "options" => ["", "甲", "乙"], "recommend" => 1}]
  }
  comment = triage_comment(verdict)
  assert_includes comment, "- [ ] **A** 甲（推荐）"
  assert_includes comment, "- [ ] **B** 乙"
end

# recommend 指向被过滤掉的空项：不得把推荐转嫁给别的选项。
def test_triage_does_not_migrate_recommend_from_empty_option
  verdict = {
    "decision" => "needs-design", "body" => "x",
    "questions" => [{"q" => "选哪个", "options" => ["", "甲", "乙"], "recommend" => 0}]
  }
  comment = triage_comment(verdict)
  refute_includes comment, "（推荐）"
  assert_includes comment, "- [ ] **A** 甲"
end

# 空问题列表不产出小节；选项为空时给出「待补充选项」而不是静默省略。
def test_triage_question_edge_cases
  refute_includes triage_comment({"decision" => "needs-design", "body" => "x", "questions" => []}), "待决问题"
  refute_includes triage_comment({"decision" => "needs-design", "body" => "x"}), "待决问题"
  empty_options = triage_comment({"decision" => "needs-design", "body" => "x",
    "questions" => [{"q" => "待定项", "options" => []}]})
  assert_includes empty_options, "待补充选项"
end

# 结构非法必须拒绝执行，不能静默丢弃待决问题——丢了调用方看不出。
def test_triage_rejects_malformed_questions
  [
    {"decision" => "needs-design", "body" => "x", "questions" => {"q" => "x"}},
    {"decision" => "needs-design", "body" => "x", "questions" => [false]},
    {"decision" => "needs-design", "body" => "x", "questions" => [{"q" => ""}]},
    {"decision" => "needs-design", "body" => "x", "questions" => [{"q" => "x", "options" => "甲乙"}]}
  ].each do |verdict|
    error = assert_raises(SebasAgents::InvalidPlan) { triage_comment(verdict) }
    assert_includes error.message, "questions"
  end
end

  def test_triage_proposal_acceptance_requires_maintainer_evidence
    data = snapshot(issues: [issue(8, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      verdict = File.join(dir, "v.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      File.write(verdict, JSON.generate({"decision" => "accepted-design", "body" => "接受"}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "maintainer_decision_url"
    end
  end

  def test_triage_proposal_acceptance_clears_states_without_assigning
    data = snapshot(issues: [issue(8, labels: ["proposal", "proposal:needs-design"])])
    Dir.mktmpdir do |dir|
      snap, verdict, url = proposal_verdict(data, dir)
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 0, status
      payload = JSON.parse(out)
      actions = payload["actions"]
      assert(actions.any? { |action| action["action"] == "add_label" && action["name"] == "proposal:accepted-design" })
      assert(actions.any? { |action| action["action"] == "remove_label" && action["name"] == "proposal:needs-design" })
      assert_includes payload["comment"], url
      assert_includes payload["comment_preview"], url
      refute(actions.any? { |action| %w[add_assignee suggest_milestone close].include?(action["action"]) })
    end
  end

  def test_triage_proposal_decisions_require_proposal_label
    data = snapshot(issues: [issue(7, labels: ["enhancement"])])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      verdict = File.join(dir, "v.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      File.write(verdict, JSON.generate({"decision" => "needs-design"}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "7", "--snapshot", snap, "--verdict", verdict])
      assert_equal 2, status
      assert_includes out, "proposal 标签"
    end
  end

  def test_triage_proposal_decline_records_reason_and_closes
    data = snapshot(issues: [issue(8, labels: ["proposal", "proposal:accepted-design"])])
    Dir.mktmpdir do |dir|
      snap, verdict, = proposal_verdict(data, dir, decision: "declined")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 0, status
      actions = JSON.parse(out)["actions"]
      assert(actions.any? { |action| action["action"] == "add_label" && action["name"] == "proposal:declined" })
      assert(actions.any? { |action| action["action"] == "close" && action["reason"] == "not planned" })
      assert(actions.any? { |action| action["action"] == "remove_label" && action["name"] == "proposal:accepted-design" })
      refute(actions.any? { |action| %w[add_assignee suggest_milestone].include?(action["action"]) })
    end
  end

# 被取代与被拒绝处置相同（关闭 not planned），但标签与回链不同：
# 没有继任编号就无法从旧档案跳到新设计，等于断链。
  def test_triage_proposal_superseded_requires_successor
        # 继任者必须真实存在且带 proposal 标签，否则校验会拒绝。
    data = snapshot(issues: [
      issue(8, labels: ["proposal", "proposal:accepted-design"]),
      issue(9, labels: ["proposal"])
    ])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      verdict = File.join(dir, "v.json")
      File.write(verdict, JSON.generate({"decision" => "superseded", "body" => "方向被替换"}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "superseded_by"
    end
  end

  def test_triage_proposal_superseded_closes_and_links_successor
    # 继任者必须真实存在且带 proposal 标签，否则校验会拒绝。
    data = snapshot(issues: [
      issue(8, labels: ["proposal", "proposal:accepted-design"]),
      issue(9, labels: ["proposal"])
    ])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      verdict = File.join(dir, "v.json")
      File.write(verdict, JSON.generate({"decision" => "superseded", "body" => "方向被替换", "superseded_by" => 9}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 0, status
      payload = JSON.parse(out)
      actions = payload["actions"]
      assert(actions.any? { |action| action["action"] == "add_label" && action["name"] == "proposal:superseded" })
      assert(actions.any? { |action| action["action"] == "close" && action["reason"] == "not planned" })
      assert_includes payload["comment"], "继任 Proposal：#9"
    end
  end

  def test_triage_proposal_superseded_rejects_self_reference
    data = snapshot(issues: [issue(8, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      verdict = File.join(dir, "v.json")
      File.write(verdict, JSON.generate({"decision" => "superseded", "superseded_by" => 8}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "自身"
    end
  end

  def test_triage_proposal_rejects_untrusted_or_unbound_verdicts
    data = snapshot(issues: [issue(8, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      [
        ["https://github.com/other/r/issues/8#issuecomment-123", "当前仓库"],
        ["https://github.com/o/r/issues/9#issuecomment-123", "当前 Proposal"]
      ].each do |url, message|
        snap, verdict, = proposal_verdict(data, dir, url: url)
        status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
        assert_equal 1, status
        assert_includes out, message
      end

      snap, verdict, url = proposal_verdict(data, dir)
      data["proposal_evidence"][url]["author"] = "external-user"
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "Maintainer"

      data["proposal_evidence"][url]["author"] = "ShiningRay"
      data["proposal_evidence"][url].delete("body")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "裁决正文"
    end
  end

  def test_triage_proposal_rejects_cross_repo_short_backlink
    url = "https://github.com/o/r/pull/9#discussion_r123"
    data = snapshot(issues: [issue(8, labels: ["proposal"])], pull_requests: [{"number" => 9, "body" => "Design other/r#8"}])
    Dir.mktmpdir do |dir|
      snap, verdict, = proposal_verdict(data, dir, url: url)
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "回链"
    end
  end

  def test_triage_proposal_design_pr_verdict_requires_backlink
    url = "https://github.com/o/r/pull/9#discussion_r123"
    data = snapshot(issues: [issue(8, labels: ["proposal"])], pull_requests: [{"number" => 9, "body" => ""}])
    Dir.mktmpdir do |dir|
      snap, verdict, = proposal_verdict(data, dir, url: url)
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "回链"

      data["pull_requests"][0]["body"] = "Design: https://github.com/o/r/issues/8"
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 0, status, out

      data["pull_requests"][0]["body"] = "Design: https://github.com/other/r/issues/8"
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "回链"
    end
  end

  def test_triage_proposal_decline_requires_nonempty_reason
    data = snapshot(issues: [issue(8, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      snap, verdict, url = proposal_verdict(data, dir, decision: "declined")
      data["proposal_evidence"][url]["body"] = "<!-- proposal-verdict: declined -->"
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "理由"
    end
  end

  def test_triage_proposal_rejects_assignment_and_scheduling_decisions
    data = snapshot(issues: [issue(8, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      %w[accepted bug-confirmed rejected fixed by-design].each do |decision|
        snap = File.join(dir, "s.json")
        verdict = File.join(dir, "v.json")
        File.write(snap, JSON.generate(data), encoding: "UTF-8")
        File.write(verdict, JSON.generate({"decision" => decision}), encoding: "UTF-8")
        status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
        assert_equal 1, status
        assert_includes out, "Proposal 只允许"
      end
    end
  end

  def test_triage_proposal_preserves_clarification_duplicate_and_escalation
    data = snapshot(issues: [issue(8, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      {"needs-info" => "question", "duplicate" => "close", "escalate" => "notify_maintainer"}.each do |decision, expected|
        snap = File.join(dir, "s.json")
        verdict = File.join(dir, "v.json")
        File.write(snap, JSON.generate(data), encoding: "UTF-8")
        File.write(verdict, JSON.generate({"decision" => decision, "body" => "说明"}), encoding: "UTF-8")
        _status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
        actions = JSON.parse(out)["actions"]
        assert(actions.any? { |action| action["action"] == expected || action["name"] == expected })
        refute(actions.any? { |action| %w[add_assignee suggest_milestone].include?(action["action"]) })
      end
    end
  end

  def test_next_with_snapshot
    data = snapshot(issues: [issue(1, body: automation(order: [4]))])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["next", "--snapshot", path, "--record", File.join(dir, "run.json")])
      assert_equal 0, status
      assert_equal "claim_issue", JSON.parse(out)["action"]
    end
  end

  def test_invalid_plan_exits_refused
    data = snapshot(issues: [
      issue(1, body: automation(order: [4, 1])),
      issue(2, body: automation(order: [4, 1]))
    ])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["next", "--snapshot", path, "--record", File.join(dir, "run.json")])
      assert_equal 1, status
      payload = JSON.parse(out)
      assert_equal "invalid_plan", payload["action"]
      refute payload["ok"]
    end
  end

# 独立小修的唯一开工方式：人工点名 claim。claim 不校验 milestone，但要求它是小修。
def test_claim_accepts_small_fix_without_milestone
  data = snapshot(issues: [issue(903, body: automation(order: [4, 1]), milestone: nil, type: "Task")])
  Dir.mktmpdir do |dir|
    path = File.join(dir, "snapshot.json")
    File.write(path, JSON.generate(data), encoding: "UTF-8")
    status, out, = run_cli(["claim", "903", "--snapshot", path, "--record", File.join(dir, "run.json")])
    assert_equal 0, status
    assert_equal "ready", JSON.parse(out)["status"]
  end
end

# 无 milestone 的 Feature 不能认领：那会绕开 milestone 容量与 DAG 检查。
def test_claim_rejects_milestone_less_feature
  data = snapshot(issues: [issue(904, body: automation(order: [4, 1]), milestone: nil, type: "Feature")])
  Dir.mktmpdir do |dir|
    path = File.join(dir, "snapshot.json")
    File.write(path, JSON.generate(data), encoding: "UTF-8")
    status, out, = run_cli(["claim", "904", "--snapshot", path, "--record", File.join(dir, "run.json")])
    assert_equal 1, status
    assert_includes JSON.parse(out)["reasons"].join, "不是独立小修"
  end
end

# 自称小修却带前置：无 milestone 约束 + 声明依赖属矛盾状态，不得豁免。
def test_claim_rejects_small_fix_with_dependencies
  data = snapshot(issues: [
    issue(905, body: automation(order: [4, 1], depends_on: [7]), milestone: nil, type: "Task"),
    issue(7, body: automation(order: [4, 2]), blocked_by: [])
  ])
  Dir.mktmpdir do |dir|
    path = File.join(dir, "snapshot.json")
    File.write(path, JSON.generate(data), encoding: "UTF-8")
    status, out, = run_cli(["claim", "905", "--snapshot", path, "--record", File.join(dir, "run.json")])
    assert_equal 1, status
    assert_includes JSON.parse(out)["reasons"].join, "不是独立小修"
  end
end

  def test_claim_dry_run_does_not_write_record
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["claim", "1", "--snapshot", path, "--record", record])
      assert_equal 0, status
      assert JSON.parse(out)["dry_run"]
      refute File.exist?(record)
    end
  end

  # --apply 需要真实标签写入与回读；此处只验证 dry-run 不落盘，
  # 以及写授权机制本身（见 DryRunGuardTest）。
  def test_claim_apply_claims_only_with_verified_label
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["claim", "1", "--snapshot", path, "--record", record, "--apply",
        "--repo", "invalid/does-not-exist-zzz"])
      # 仓库不可达时不得声称 claimed
      assert_includes [1, 2], status
      payload = JSON.parse(out)
      refute_equal "claimed", payload["claim"]
    end
  end

  # 快照仓库与 --repo 不一致时必须拒绝写入，否则会认领到没校验过的仓库。
  def test_claim_rejects_repo_mismatch
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["claim", "1", "--snapshot", path, "--record", record, "--apply",
        "--repo", "other/repo"])
      assert_equal 2, status
      assert_equal "usage_error", JSON.parse(out)["error"]["code"]
      refute File.exist?(record), "拒绝时不得留下运行记录"
    end
  end

  # 写入失败也要落 aborted，不能让记录停在 claiming。
  def test_claim_write_failure_records_aborted
    data = snapshot(issues: [issue(1, body: automation)])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      record = File.join(dir, "run.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")

      # 用假 runner：写 status 抛错，其余按成功返回。
      fake = Class.new(SebasAgents::CommandRunner) do
        def run!(*argv, chdir: Dir.pwd)
          raise SebasAgents::CommandError.new("boom", command: argv) if argv.any? { |arg| arg.start_with?("status=") }

          ""
        end
      end

      cli = SebasAgents::CLI.new(out: StringIO.new, err: StringIO.new)
      cli.define_singleton_method(:runner) { |_options| fake.new(dry_run: false) }
      out = StringIO.new
      cli.instance_variable_set(:@out, out)
      status = cli.run(["claim", "1", "--snapshot", path, "--record", record, "--apply"])
      assert_equal 1, status
      saved = JSON.parse(File.read(record, encoding: "UTF-8"))
      assert_equal "aborted", saved["phase"], "写入失败必须落 aborted"
      assert_equal false, saved["status_written"]
      refute JSON.parse(out.string)["ok"]
    end
  end

  def test_dry_run_blocks_git_writes
    runner = SebasAgents::CommandRunner.new(dry_run: true)
    result = runner.capture("git", "push", "origin", "main")
    assert result.success?
    assert_equal [%w[git push origin main]], runner.calls
  end

# Proposal 带合法 work_package Automation 块也不得进入 Implementer 选卡：
# 与 in_progress_issues 同口径，否则提案会被当作工作认领。
def test_selection_excludes_proposal_even_with_valid_automation
  block = "```json automation\n" \
    "{\"schema\":1,\"kind\":\"work_package\",\"order\":[4,1],\"depends_on\":[],\"external\":[]}\n```\n"
  data = snapshot(issues: [issue(8, body: block, labels: ["proposal"])])
  action = select(data)
  refute_equal "claim_issue", action.action
  assert(action.excluded.any? { |row| row["reason"].to_s.include?("proposal") }, action.excluded.inspect)
end

  # 有 Automation 块但结构残缺时不能短路成工作包：会按坏元数据写 type/assignee。
  # 也不能静默降级为普通研判——必须显式拒绝。
  def test_triage_rejects_malformed_automation_block
    data = snapshot(issues: [issue(7, body: "```json automation\n{\"kind\":\"work_package\"}\n```\n")])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "7", "--snapshot", snap])
      assert_equal 1, status
      assert_includes out, "invalid_plan"
    end
  end

  # Proposal 即使带 Automation 块也走专用判定，不得被工作包短路抢走。
  def test_triage_proposal_with_automation_block_still_uses_proposal_rules
    block = "```json automation\n" \
      "{\"schema\":1,\"kind\":\"work_package\",\"order\":[1],\"depends_on\":[],\"external\":[]}\n```\n"
    data = snapshot(issues: [issue(8, body: block, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap])
      assert_equal 1, status
      assert_equal "needs-model-verdict", JSON.parse(out)["decision"]
    end
  end
end

class JsonBlockTest < Minitest::Test
  def test_rejects_duplicate_blocks
    body = "```json automation\n{\"kind\":\"work_package\"}\n```\n```json automation\n{\"kind\":\"tracking\"}\n```\n"
    assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::JsonBlock.one(body, "automation", subject: "issue #1")
    end
  end

  def test_rejects_invalid_json
    assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::JsonBlock.one("```json automation\n{nope}\n```\n", "automation", subject: "issue #1")
    end
  end

  def test_ignores_unlabelled_json_fence
    body = "```json\n{\"kind\":\"tracking\"}\n```\n"
    assert_nil SebasAgents::JsonBlock.one(body, "automation", subject: "issue #1")
  end

  # Windows 客户端写的 issue body 是 CRLF；曾导致所有元数据"看起来不存在"。
  def test_parses_crlf_body
    body = "## Automation\r\n\r\n```json automation\r\n{\"schema\":1,\"kind\":\"work_package\"}\r\n```\r\n"
    parsed = SebasAgents::JsonBlock.one(body, "automation", subject: "issue #1")
    assert_equal "work_package", parsed["kind"]
    assert SebasAgents::JsonBlock.present?(body, "automation")
  end

  def test_parses_mixed_line_endings
    body = "text\r\n```json automation\n{\"kind\":\"tracking\"}\r\n```\n"
    assert_equal "tracking", SebasAgents::JsonBlock.one(body, "automation", subject: "issue #1")["kind"]
  end
end

class DryRunGuardTest < Minitest::Test
  # 复核列出的真实写命令形态，全部必须被拦。
  WRITE_COMMANDS = [
    %w[git push origin main],
    %w[git commit -m x],
    %w[git tag v1.0.0],
    %w[git checkout -b feat/x],
    %w[git switch main],
    %w[git reset --hard],
    %w[git add -A],
    %w[git stash],
    ["git", "-C", "/repo", "commit", "-m", "x"],
    ["git", "--git-dir", "/repo/.git", "commit", "-m", "x"],
    ["gh", "issue", "edit", "1", "--add-label", "bug"],
    ["gh", "issue", "close", "1"],
    ["gh", "issue", "comment", "1", "--body", "x"],
    ["gh", "issue", "develop", "1"],
    ["gh", "pr", "merge", "5", "--squash"],
    ["gh", "pr", "create", "--title", "t"],
    ["gh", "pr", "update-branch", "5"],
    ["gh", "-R", "o/r", "pr", "merge", "5"],
    ["gh", "--repo", "o/r", "issue", "comment", "1", "--body", "x"],
    ["gh", "label", "create", "bug"],
    ["gh", "api", "repos/o/r/issues/1", "-X", "POST", "-f", "body=x"],
    ["gh", "api", "repos/o/r/issues/1/comments", "-f", "body=x"],
    ["gh", "api", "repos/o/r/issues/1/comments", "-fbody=x"],
    ["gh", "api", "repos/o/r/issues", "--input", "payload.json"],
    ["gh", "api", "--method=POST", "repos/o/r/issues"],
    ["gh", "api", "-X", "DELETE", "repos/o/r/issues/1"],
    ["gh", "release", "create", "v1.0.0"],
    ["gh", "release", "upload", "v1", "f.zip"]
  ].freeze

  READ_COMMANDS = [
    %w[git log --oneline],
    %w[git describe --tags --abbrev=0],
    %w[git rev-parse HEAD],
    %w[git status --short],
    ["git", "-C", "/repo", "log", "--oneline"],
    ["gh", "api", "repos/o/r/issues"],
    ["gh", "api", "-X", "GET", "repos/o/r/issues", "-f", "state=open"],
    # graphql 的 -f 只是查询变量，必须放行，否则默认 next 在有 open PR 时必失败
    ["gh", "api", "graphql", "-f", "query=query{viewer{login}}"],
    ["gh", "pr", "list", "--json", "number"],
    ["gh", "pr", "view", "5", "--json", "state"],
    ["gh", "issue", "view", "1", "--json", "body"],
    ["gh", "issue", "list", "--json", "number"],
    ["gh", "-R", "o/r", "issue", "view", "1"],
    ["gh", "status"]
  ].freeze

  def test_write_commands_are_never_executed
    WRITE_COMMANDS.each do |argv|
      runner = SebasAgents::CommandRunner.new(dry_run: true)
      refute runner.send(:read_only?, argv), "未拦截写命令：#{argv.join(" ")}"
      result = runner.capture(*argv)
      assert result.success?, "dry-run 应返回假成功：#{argv.join(" ")}"
      assert_equal "", result.stdout, "dry-run 不得返回伪数据：#{argv.join(" ")}"
    end
  end

  def test_read_commands_are_executed
    READ_COMMANDS.each do |argv|
      runner = SebasAgents::CommandRunner.new(dry_run: true)
      assert runner.send(:read_only?, argv), "误把只读命令当写：#{argv.join(" ")}"
    end
  end

  def test_unknown_command_is_blocked_by_default
    # 白名单语义：无法确认只读的命令默认不执行。
    runner = SebasAgents::CommandRunner.new(dry_run: true)
    refute runner.send(:read_only?, ["curl", "https://example.com"]), "未知命令应默认拦截"
    refute runner.send(:read_only?, ["gh", "extension", "exec", "x"]), "未知 gh 子命令应默认拦截"
  end

  def test_apply_mode_allows_writes
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    refute runner.dry_run?
  end

  # 断言子进程真的被调用，而不是只看 calls 记录（记录在拦截前就写了）。
  def test_write_authorization_is_scoped
    add = ["gh", "issue", "edit", "39", "--repo", "o/r", "--add-label", "agent:in-progress"]
    merge = ["gh", "pr", "merge", "5"]
    executed = []

    Open3.singleton_class.alias_method(:__orig_capture3, :capture3)
    Open3.define_singleton_method(:capture3) do |*argv, **_opts|
      executed << argv
      ["", "", Struct.new(:success?).new(true)]
    end

    begin
      runner = SebasAgents::CommandRunner.new(dry_run: true)
      runner.capture(*add)
      runner.capture(*merge)
      assert_empty executed, "dry-run 不得真正执行写命令"

      runner.with_write(:add_label) { runner.capture(*add) }
      assert_equal [add], executed, "授权后 add-label 必须真实执行"

      runner.with_write(:add_label) { runner.capture(*merge) }
      assert_empty executed.select { |c| c.include?("merge") }, "授权 add-label 不应放行 merge"

      runner.capture(*add)
      assert_equal 1, executed.count { |c| c.include?("--add-label") }, "离开授权后恢复拦截"
    ensure
      Open3.singleton_class.alias_method(:capture3, :__orig_capture3)
    end
  end

  # 重试耗尽后，错误必须带 command 与 stderr，否则上游无法定位。
  def test_retry_exhaustion_keeps_command_context
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    calls = 0
    runner.define_singleton_method(:with_retry) do |&block|
      block.call
    end
    runner.singleton_class.send(:remove_method, :with_retry)
    runner.define_singleton_method(:with_retry) do
      calls += 1
      SebasAgents::CommandRunner::Result.new(stdout: "", stderr: "unexpected EOF\n",
        status: Struct.new(:success?).new(false))
    end
    assert_raises(SebasAgents::CommandError) { runner.run!("gh", "api", "x") }
    error = begin
      runner.run!("gh", "api", "x")
    rescue SebasAgents::CommandError => e
      e
    end
    assert_equal ["gh", "api", "x"], error.command
    assert_includes error.stderr.to_s, "EOF"
    assert_includes error.message, "gh api x"
  end
end


class ClosedIssueLabelTest < Minitest::Test
  include SnapshotHelpers

  def test_closed_issue_with_stale_label_is_not_active_claim
    data = snapshot(issues: [
      issue(1, body: automation, status: "In progress", state: "CLOSED", state_reason: "COMPLETED"),
      issue(2, body: automation(order: [4, 2]))
    ])
    assert_equal "claim_issue", select(data).action
  end
end

# #125：合并后 Verifier 的三类确定性检查——路径联动、安全不变量、CWE 汇总。
class PathChecksTest < Minitest::Test
  def change(path, patch)
    SebasAgents::PathChecks::Change.new(path: path, patch: patch)
  end

  def run_check(changes, body: "", threads: [])
    report = SebasAgents::VerificationReport.new
    SebasAgents::PathChecks.check(changes: changes, body: body, threads: threads, report: report)
    report
  end

  # 验收 1：只改 src/ 不改 spec/ → blocker。
  def test_src_change_without_spec_blocks
    report = run_check([change("src/store/store.cr", "+def x; end\n")])
    assert report.blockers.any? { |i| i.message.include?("spec/") }
  end

  # 验收 2：workflow 用 @v4 而非 SHA → blocker。
  def test_unpinned_workflow_uses_blocks
    report = run_check([change(".github/workflows/ci.yml", "+      uses: actions/checkout@v4\n")])
    assert report.blockers.any? { |i| i.message.include?("未钉 SHA") }
  end

  # 钉了 40 位 sha 的 uses 不报。
  def test_sha_pinned_uses_passes
    sha = "a" * 40
    report = run_check([change(".github/workflows/ci.yml", "+      uses: actions/checkout@#{sha}\n")])
    assert report.blockers.empty?, report.blockers.map(&:message).inspect
  end

  # 验收 3：未 resolve 的 CWE 意见 → blocker；resolve 后不再阻断。
  def test_unresolved_cwe_blocks_and_resolved_passes
    threads = [{"isResolved" => false, "path" => "src/x.cr",
                "comments" => [{"body" => "授权绕过，见 CWE-862 与 CWE-863。"}]}]
    report = run_check([], threads: threads)
    assert report.blockers.any? { |i| i.message.include?("CWE-862") }

    resolved = threads.map { |t| t.merge("isResolved" => true) }
    report = run_check([], threads: resolved)
    assert report.blockers.empty?
  end

  # 验收 4：全合规 → 通过（无 blocker/must_fix）。
  def test_fully_compliant_change_passes
    sha = "b" * 40
    body = "行为变更已同步文档；安全边界：workflow 全部 SHA 钉版。"
    changes = [
      change("src/store/store.cr", "+def y; end\n"),
      change("spec/store/store_spec.cr", "+it \"y\" do\nend\n"),
      change("docs/design/design.md", "+## 新行为\n"),
      change(".github/workflows/ci.yml", "+      uses: actions/checkout@#{sha}\n")
    ]
    report = run_check(changes, body: body)
    assert report.pass?, report.items.map(&:message).inspect
  end

  # tools/ 有实质改动但 tools/test_*.rb 无变更 → blocker。
  def test_tools_change_without_tests_blocks
    report = run_check([change("tools/new_script.rb", "+puts 1\n")])
    assert report.blockers.any? { |i| i.message.include?("tools/test_*.rb") }
  end

  # 纯空白/注释改动豁免 spec 联动，且以 acceptable 留痕。
  def test_comment_only_src_change_is_exempted_with_trail
    report = run_check([change("src/store/store.cr", "+# 注释说明\n-# 旧注释\n+  \n")])
    refute report.blockers.any? { |i| i.message.include?("spec/") }
    assert report.acceptable_items.any? { |i| i.message.include?("空白/注释") }
  end

  # src 改动 + 正文声明「无行为变更」→ 文档联动豁免。
  def test_no_behavior_change_declaration_exempts_docs
    report = run_check([change("src/store/store.cr", "+def x; end\n"),
                        change("spec/store/store_spec.cr", "+it {}\n")],
      body: "本次为内部重构，无行为变更")
    refute report.must_fix_items.any? { |i| i.message.include?("docs/") }
  end

  # workflow 改动缺「安全边界」说明 → must_fix；有声明则豁免。
  def test_workflow_change_requires_security_boundary_note
    sha = "c" * 40
    report = run_check([change(".github/workflows/ci.yml", "+      uses: x/y@#{sha}\n")])
    assert report.must_fix_items.any? { |i| i.message.include?("安全边界") }

    report = run_check([change(".github/workflows/ci.yml", "+      uses: x/y@#{sha}\n")], body: "安全边界：无新增权限")
    assert report.must_fix_items.empty?
  end

  # 凭据正则：puts + token 同行 → must_fix。
  def test_credential_in_log_line_is_must_fix
    report = run_check([change("src/keys/store.cr", "+    puts token_info\n")])
    assert report.must_fix_items.any? { |i| i.message.include?("凭据") }
  end

  # 规则文件自身与测试文件不扫凭据正则（避免自触发）。
  def test_rule_and_test_files_are_not_scanned
    report = run_check([change("tools/test_path_checks.rb", "+    puts token_info\n"),
                        change("tools/agents/lib/sebas_agents/path_checks.rb", "+  CREDENTIAL_LINE = /puts.*token/\n")])
    assert report.must_fix_items.empty?
  end

  # evidence.rb 触碰 SOURCES → blocker。
  def test_evidence_sources_touch_blocks
    report = run_check([change("tools/agents/lib/sebas_agents/policy/evidence.rb",
      "+      SOURCES = {\"workflow\" => ...}\n")])
    assert report.blockers.any? { |i| i.message.include?("SOURCES") }
  end

  # workflow 中的 force-push / 分支保护写入 → blocker。
  def test_force_push_and_branch_protection_block
    report = run_check([change(".github/workflows/rel.yml", "+      git push --force origin main\n")])
    assert report.blockers.any? { |i| i.message.include?("push 保护") }
    report = run_check([change(".github/workflows/rel.yml", "+      gh api repos/o/r/branches/main/protection -X PUT\n")])
    assert report.blockers.any? { |i| i.message.include?("分支保护") }
  end
end

# #125：verify_merge 的 pre 模式接线——快照提供 files/body 时执行，缺省留痕。
class PathChecksIntegrationTest < Minitest::Test
  include SnapshotHelpers

  def run_pre(data)
    SebasAgents::Verifier.verify_merge(
      10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true
    )
  end

  # 与既有合并前 fixture 同构（SnapshotHelpers 原语自构）。
  def pre_data_with_pr_extra(issue_body:, pr_extra: {})
    snapshot(
      issues: [issue(39, body: issue_body)],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}],
        "review_threads" => []
      }.merge(pr_extra)],
      trusted_bots: ["github-actions[bot]"],
      source_authors: {
        "https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"
      },
      source_bodies: {
        "https://github.com/o/r/issues/1#issuecomment-1" => evidence(
          subject: "issue:39", merged: false, source: "workflow"
        )
      }
    )
  end

  def test_snapshot_without_files_leaves_unverified_trail
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    report = run_pre(pre_data_with_pr_extra(issue_body: body))
    assert report.pass?, "缺 files 不产生 blocker"
    assert report.unverified_items.any? { |i| i.message.include?("变更文件清单") }
  end

  def test_snapshot_with_violating_files_blocks
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    files = [{"filename" => "src/store/new.cr", "patch" => "+def x; end\n"}]
    report = run_pre(pre_data_with_pr_extra(issue_body: body, pr_extra: {"files" => files, "body" => "PR 正文"}))
    refute report.pass?
    assert report.blockers.any? { |i| i.message.include?("spec/") }
  end

  def test_snapshot_with_compliant_files_passes
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    files = [{"filename" => "src/store/new.cr", "patch" => "+def x; end\n"},
             {"filename" => "spec/store/new_spec.cr", "patch" => "+it \"x\" do\nend\n"},
             {"filename" => "docs/design/design.md", "patch" => "+## x\n"}]
    report = run_pre(pre_data_with_pr_extra(
      issue_body: body,
      pr_extra: {"files" => files, "body" => "文档已同步；安全边界：无 workflow 改动"}
    ))
    assert report.pass?, "全合规应通过：#{report.items.map(&:message).inspect}"
  end
end

# #125 第一轮 CodeRabbit 复审（7 条）回归。
class PathChecksRound2Test < Minitest::Test
  def change(path, patch)
    SebasAgents::PathChecks::Change.new(path: path, patch: patch)
  end

  def run_check(changes, body: "", threads: [])
    report = SebasAgents::VerificationReport.new
    SebasAgents::PathChecks.check(changes: changes, body: body, threads: threads, report: report)
    report
  end

  # jobI：patch 缺失的文件必须显式拒绝核验，不按空改动放行。
  def test_missing_patch_fails_closed
    report = run_check([change(".github/workflows/ci.yml", nil)], body: "安全边界：略")
    assert report.blockers.any? { |i| i.message.include?("无 patch 内容") }
  end

  # jobJ：注释里的假 sha 骗不过；带引号的合法引用能过。
  def test_uses_value_is_validated_whole
    report = run_check([change(".github/workflows/ci.yml",
      "+      uses: actions/checkout@v4 # uses: x/y@#{'a' * 40}\n")])
    assert report.blockers.any? { |i| i.message.include?("未钉 SHA") }, "注释中的 40 位文本不能代替字段校验"

    quoted = run_check([change(".github/workflows/ci.yml",
      "+      uses: \"actions/checkout@#{'b' * 40}\"\n")])
    assert quoted.blockers.empty?, quoted.blockers.map(&:message).inspect
  end

  # jobD：git push -f 短参数也拦；普通 push 不拦。
  def test_git_push_short_force_flag_blocks
    report = run_check([change(".github/workflows/rel.yml", "+      git push -f origin main\n")])
    assert report.blockers.any? { |i| i.message.include?("push 保护") }
    report = run_check([change(".github/workflows/rel.yml", "+      git push origin main\n")])
    assert report.blockers.empty?, report.blockers.map(&:message).inspect
  end

  # jobK：读取分支保护配置（GET）不触发；新增写方法触发。
  def test_branch_protection_read_does_not_block
    report = run_check([change(".github/workflows/rel.yml", "+      gh api repos/o/r/branches/main/protection\n")])
    assert report.blockers.empty?, "只读 GET 不应触发"
    report = run_check([change(".github/workflows/rel.yml", "+      gh api repos/o/r/branches/main/protection -X PUT\n")])
    assert report.blockers.any? { |i| i.message.include?("分支保护") }
  end

  # jobF：test_ 前缀的 Markdown 不满足 tools 测试联动。
  def test_tools_test_pattern_requires_rb
    report = run_check([change("tools/new_script.rb", "+puts 1\n"),
                        change("tools/test_notes.md", "+note\n")])
    assert report.blockers.any? { |i| i.message.include?("tools/test_*.rb") }

    ok = run_check([change("tools/new_script.rb", "+puts 1\n"),
                    change("tools/test_new_script.rb", "+assert true\n")])
    refute ok.blockers.any? { |i| i.message.include?("tools/test_*.rb") }
  end

  # jobG：纯注释 src 改动同时豁免文档联动，完整报告通过。
  def test_comment_only_src_change_exempts_docs_linkage
    report = run_check([change("src/store/store.cr", "+# 注释\n-# 旧注释\n")])
    assert report.pass?, "纯注释改动应完整通过：#{report.items.map(&:message).inspect}"
    assert report.acceptable_items.any?
  end
end

# #125 第一轮复审 jobB：混合快照 fail-closed（gateway 层）。
class PrDetailsHeadMismatchTest < Minitest::Test
  # 用 FakeRunner 模拟 gh api 返回，验证 head 不一致时抛错。
  class StubRunner
    Result = Struct.new(:stdout)
    def initialize(responses)
      @responses = responses
    end

    def json!(*_argv)
      r = @responses.shift
      JSON.parse(r)
    end
  end

  def test_head_mismatch_raises
    gateway = SebasAgents::GithubGateway.new(
      StubRunner.new(['{"body": "b", "head_sha": "new"}', "[]"]), repo: "o/r"
    )
    error = assert_raises(SebasAgents::CommandError) do
      gateway.send(:fetch_pr_details, 10, expected_head: "old")
    end
    assert_includes error.message, "混合快照"
  end

  def test_head_match_proceeds
    gateway = SebasAgents::GithubGateway.new(
      StubRunner.new(['{"body": "b", "head_sha": "same"}',
                      '[{"filename": "a.rb", "patch": "+x"}]',
                      '{"body": "b", "head_sha": "same"}']),
      repo: "o/r"
    )
    details = gateway.send(:fetch_pr_details, 10, expected_head: "same")
    assert_equal "b", details["body"]
    assert_equal 1, details["files"].length
  end
end

# #125 第二轮复审（3 条）回归。
class PathChecksRound3Test < Minitest::Test
  def change(path, patch)
    SebasAgents::PathChecks::Change.new(path: path, patch: patch)
  end

  def run_check(changes, body: "", threads: [])
    report = SebasAgents::VerificationReport.new
    SebasAgents::PathChecks.check(changes: changes, body: body, threads: threads, report: report)
    report
  end

  # julr：删除未钉引用 + 新增钉版引用 = 正常修复，不得报 blocker。
  def test_deleted_unpinned_uses_does_not_block
    report = run_check([change(".github/workflows/ci.yml",
      "-      uses: actions/checkout@v4\n+      uses: actions/checkout@#{'a' * 40}\n")])
    assert report.blockers.empty?, report.blockers.map(&:message).inspect
  end

  # juln：--method 空格形式与 -X 前置都拦；不依赖路径与方法顺序；GET 不拦。
  def test_branch_protection_write_method_variants
    variants = [
      "+      gh api repos/o/r/branches/main/protection --method PUT\n",
      "+      gh api -X PUT repos/o/r/branches/main/protection\n",
      "+      gh api repos/o/r/branches/main/protection -X DELETE\n"
    ]
    variants.each do |patch|
      report = run_check([change(".github/workflows/rel.yml", patch)])
      assert report.blockers.any? { |i| i.message.include?("分支保护") }, patch
    end
    get_only = run_check([change(".github/workflows/rel.yml", "+      gh api repos/o/r/branches/main/protection\n")])
    assert get_only.blockers.empty?
  end

  # jobI 补充：patch 缺失同时不产生其他误判条目。
  def test_missing_patch_only_reports_the_missing_file
    report = run_check([change("src/new.cr", nil)])
    assert_equal 1, report.blockers.length
    assert_includes report.blockers.first.message, "src/new.cr"
  end
end

# julm：files 请求后二次回读 head——两次夹缝任一变化都抛错。
class PrDetailsSecondReadTest < Minitest::Test
  class SeqRunner
    def initialize(responses)
      @responses = responses
    end

    def json!(*_argv)
      JSON.parse(@responses.shift)
    end
  end

  def test_head_changed_during_files_request_raises
    gateway = SebasAgents::GithubGateway.new(
      SeqRunner.new([
        '{"body": "b", "head_sha": "old"}',
        '[{"filename": "a.rb", "patch": "+x"}]',
        '{"body": "b", "head_sha": "new"}'
      ]), repo: "o/r"
    )
    error = assert_raises(SebasAgents::CommandError) do
      gateway.send(:fetch_pr_details, 10, expected_head: "old")
    end
    assert_includes error.message, "混合快照"
  end
end

# #125 第四轮复审：ensure_head_unchanged! 对缺失/非法输入 fail-closed。
class EnsureHeadGuardTest < Minitest::Test
  class SeqRunner
    def initialize(responses)
      @responses = responses
    end

    def json!(*_argv)
      JSON.parse(@responses.shift)
    end
  end

  def gateway_with(*responses)
    SebasAgents::GithubGateway.new(SeqRunner.new(responses), repo: "o/r")
  end

  def test_missing_expected_head_rejects
    gateway = gateway_with('{"body": "b", "head_sha": "x"}',
      '[{"filename": "a.rb", "patch": "+x"}]', '{"body": "b", "head_sha": "x"}')
    error = assert_raises(SebasAgents::CommandError) do
      gateway.send(:fetch_pr_details, 10)
    end
    assert_includes error.message, "fail-closed"
  end

  def test_non_hash_detail_rejects
    gateway = gateway_with('[]', '[]', '[]')
    error = assert_raises(SebasAgents::CommandError) do
      gateway.send(:fetch_pr_details, 10, expected_head: "old")
    end
    assert_includes error.message, "fail-closed"
  end

  def test_matching_head_proceeds
    gateway = gateway_with('{"body": "b", "head_sha": "same"}',
      '[{"filename": "a.rb", "patch": "+x"}]', '{"body": "b", "head_sha": "same"}')
    details = gateway.send(:fetch_pr_details, 10, expected_head: "same")
    assert_equal 1, details["files"].length
  end
end
