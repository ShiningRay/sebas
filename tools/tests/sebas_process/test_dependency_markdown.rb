# frozen_string_literal: true

# 正文依赖节的 CommonMark 边界：标题变体、围栏内外的 #N、CRLF、
# 尾部引用与空 ATX 标题。这些用例锁的是「解析器认不出节就静默放过」这类漏洞。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class DependencyMarkdownTest < Minitest::Test
  include SnapshotHelpers

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

  # 标题尾部带多个引用（「外部依赖 #3 #5」「#3、#5」）时，必须整串剥掉再分类。
  # 「外部依赖 #3、#5」是关键用例：剥离不彻底会残留「外部依赖 #3、」，
  # 既不匹配变体规则也过不了精确标题，因而漏检。
  def test_variant_heading_with_multiple_trailing_references
    [
      "## 外部依赖 #3 #5",
      "## 外部依赖 #3、#5",
      "## 外部依赖 #3， #5",
      "## 外部依赖 #3, #5",
      "## 依赖 #3 #5",
      "## 依赖关系 #3、#5"
    ].each do |heading|
      body = "#{heading}\n\n无。\n"
      variants = SebasAgents::Policy::Dependencies.mismatched_dependency_headings(body)
      assert_equal [heading.sub(/\A#+\s*/, "")], variants, heading
    end

    # 对照：无引用的变体照旧按规则判定（「外部依赖」下无 #N 不报）。
    assert_equal [], SebasAgents::Policy::Dependencies.mismatched_dependency_headings("## 外部依赖\n\n- E.1#1：Slack\n")
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

end
