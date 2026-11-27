# frozen_string_literal: true

# GitHub gateway 的 PR 读取：head 二次回读、GraphQL 分页守卫、fork 剔除、
# blocked_by 批量拉取。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class PrDetailsHeadMismatchTest < Minitest::Test
  include GatewayStubs

  def test_head_mismatch_raises
    gateway = SebasAgents::GithubGateway.new(
      GatewayStubs::SequenceRunner.new(['{"body": "b", "head_sha": "new"}', "[]"]), repo: "o/r"
    )
    error = assert_raises(SebasAgents::CommandError) do
      gateway.send(:fetch_pr_details, 10, expected_head: "old")
    end
    assert_includes error.message, "混合快照"
  end

  def test_head_match_proceeds
    gateway = SebasAgents::GithubGateway.new(
      GatewayStubs::SequenceRunner.new(['{"body": "b", "head_sha": "same"}',
                      '[{"filename": "a.rb", "patch": "+x"}]',
                      '{"body": "b", "head_sha": "same"}']),
      repo: "o/r"
    )
    details = gateway.send(:fetch_pr_details, 10, expected_head: "same")
    assert_equal "b", details["body"]
    assert_equal 1, details["files"].length
  end
end

class PullRequestsPaginationTest < Minitest::Test
  include GatewayStubs

  def pr_node(number:, cross: false, rollup_truncated: false, closing_truncated: false, drop_cross: false)
    {
      "number" => number, "state" => "MERGED",
      "headRefName" => "feat/#{number}", "baseRefName" => "main",
      "headRefOid" => "sha#{number}", "mergeStateStatus" => "CLEAN",
      "url" => "https://example.test/pr/#{number}",
      "closingIssuesReferences" => {
        "pageInfo" => { "hasNextPage" => closing_truncated },
        "nodes" => closing_truncated ? Array.new(10) { |i| { "number" => i } } : []
      },
      "statusCheckRollup" => {
        "contexts" => {
          "pageInfo" => { "hasNextPage" => rollup_truncated },
          "nodes" => rollup_truncated ? Array.new(100) { |i| { "name" => "check#{i}", "status" => "COMPLETED", "conclusion" => "SUCCESS" } } : []
        }
      }
    }.tap do |node|
      node["isCrossRepository"] = cross unless drop_cross
    end
  end

  def page(nodes, has_next, cursor)
    info = { "hasNextPage" => has_next }
    info["endCursor"] = cursor unless cursor.nil?
    { "data" => { "repository" => { "pullRequests" => {
      "nodes" => nodes,
      "pageInfo" => info
    } } } }
  end

  def test_paginates_until_explicit_false_with_real_cursor_advance
    payload1 = page([pr_node(number: 1), pr_node(number: 2, cross: true)], true, "cur1")
    payload2 = page([pr_node(number: 3)], false, nil)
    runner = GatewayStubs::SequenceRunner.new([JSON.generate(payload1), JSON.generate(payload2)])
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    prs = gateway.send(:fetch_pull_requests)
    # 同名 fork（cross=true）被剔除，本仓 PR 全保留——两页游标推进到底
    assert_equal [1, 3], prs.map(&:number)
    assert prs.all?(&:merged?)
    # 请求参数断言：首请求无游标，第二请求带 cursor=cur1（证明真实推进）
    refute_includes runner.argvs[0].join(" "), "cursor="
    assert_includes runner.argvs[1].join(" "), "cursor=cur1"
  end

  def test_missing_page_info_rejects_instead_of_treating_as_last_page
    payload = { "data" => { "repository" => { "pullRequests" => {
      "nodes" => [pr_node(number: 1)]
    } } } }
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "分页元数据缺失或非法"
  end

  def test_non_boolean_has_next_page_rejects
    payload = { "data" => { "repository" => { "pullRequests" => {
      "nodes" => [pr_node(number: 1)],
      "pageInfo" => { "hasNextPage" => "true", "endCursor" => "cur1" }
    } } } }
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "分页元数据缺失或非法"
  end

  def test_stuck_cursor_rejects
    payload1 = page([pr_node(number: 1)], true, "cur1")
    payload2 = page([pr_node(number: 2)], true, "cur1") # 与上一页同游标：拒绝，不循环重读
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload1), JSON.generate(payload2)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "游标未推进"
  end

  def test_nil_end_cursor_rejects
    payload1 = page([pr_node(number: 1)], true, nil) # hasNextPage=true 但游标为空
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload1)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "游标未推进"
  end

  def test_missing_is_cross_repository_rejects
    payload = page([pr_node(number: 1, drop_cross: true)], false, nil)
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "isCrossRepository"
  end

  def test_invalid_is_cross_repository_rejects
    node = pr_node(number: 1)
    node["isCrossRepository"] = "false" # 字符串非法：不得降级当 false 放行
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(page([node], false, nil))]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "isCrossRepository"
  end

  def test_truncated_rollup_contexts_reject
    payload = page([pr_node(number: 1, rollup_truncated: true)], false, nil)
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "contexts 超过 100 条"
  end

  def test_truncated_closing_issues_reject
    payload = page([pr_node(number: 1, closing_truncated: true)], false, nil)
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "closingIssuesReferences 超过 10 条"
  end

  def test_missing_nodes_rejects
    payload = { "data" => { "repository" => { "pullRequests" => {
      "pageInfo" => { "hasNextPage" => false, "endCursor" => nil }
    } } } }
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "分页缺 nodes"
  end

  def test_runaway_pagination_rejects_at_max_pages
    responses = Array.new(101) { |i| JSON.generate(page([pr_node(number: i)], true, "cur#{i}")) }
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new(responses), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "分页超过"
  end

  # round 3：fork 先剔除再查内层——fork 的异常数据不得阻断整个快照
  def test_fork_with_truncated_inner_data_excluded_without_raising
    fork = pr_node(number: 1, cross: true, closing_truncated: true)
    own = pr_node(number: 2)
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(page([fork, own], false, nil))]), repo: "o/r")
    prs = gateway.send(:fetch_pull_requests)
    assert_equal [2], prs.map(&:number)
  end

  # round 3：存在的内层连接必须有合法 pageInfo（缺失/字符串布尔都拒绝）
  def test_inner_page_info_missing_rejects
    node = pr_node(number: 1)
    node["statusCheckRollup"]["contexts"].delete("pageInfo")
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(page([node], false, nil))]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "分页元数据缺失或非法"
  end

  def test_inner_page_info_non_boolean_rejects
    node = pr_node(number: 1)
    node["statusCheckRollup"]["contexts"]["pageInfo"]["hasNextPage"] = "true"
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(page([node], false, nil))]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "分页元数据缺失或非法"
  end

  def test_inner_missing_nodes_rejects
    node = pr_node(number: 1)
    node["closingIssuesReferences"].delete("nodes")
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(page([node], false, nil))]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "缺 nodes"
  end

  # statusCheckRollup=null 合法（检查未产出，非结构非法）
  def test_null_rollup_is_legal_empty_checks
    node = pr_node(number: 1)
    node["statusCheckRollup"] = nil
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(page([node], false, nil))]), repo: "o/r")
    prs = gateway.send(:fetch_pull_requests)
    assert_equal [1], prs.map(&:number)
    assert_empty prs.first.checks
  end

  # round 4：字段缺失 ≠ 显式 null——statusCheckRollup 键整体缺失是结构非法
  def test_missing_rollup_key_rejects
    node = pr_node(number: 1)
    node.delete("statusCheckRollup")
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(page([node], false, nil))]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "缺 statusCheckRollup 连接字段"
  end

  # round 4：closingIssuesReferences 缺失会让关联 issue 从快照消失（selection 重复分配）
  def test_missing_closing_issues_connection_rejects
    node = pr_node(number: 1)
    node.delete("closingIssuesReferences")
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(page([node], false, nil))]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "缺 closingIssuesReferences 连接字段"
  end

  # round 3：errors 与有效 data 并存 = 拒绝部分成功，不得直接消费 data
  def test_errors_with_valid_data_rejects
    payload = page([pr_node(number: 1)], false, nil)
    payload["errors"] = [{ "message" => "something partial" }]
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "pullRequests 查询失败"
  end

  def test_missing_pull_requests_connection_rejects
    payload = { "data" => { "repository" => {} } }
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "查询缺 data.repository.pullRequests"
  end
end

class PrDetailsSecondReadTest < Minitest::Test
  include GatewayStubs

  def test_head_changed_during_files_request_raises
    gateway = SebasAgents::GithubGateway.new(
      GatewayStubs::SequenceRunner.new([
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

class EnsureHeadGuardTest < Minitest::Test
  include GatewayStubs

  def gateway_with(*responses)
    SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new(responses), repo: "o/r")
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

class BlockedByBatchTest < Minitest::Test
  include SnapshotHelpers
  include CliHelpers
  include GatewayStubs

  def gateway_with(*responses)
    runner = GatewayStubs::SequenceRunner.new(responses)
    [SebasAgents::GithubGateway.new(runner, repo: "o/r"), runner]
  end

  # 一份批量响应：键名 b<index>，值里的 number 是回读编号。
  def batch_payload(entries)
    data = entries.each_with_index.to_h do |entry, index|
      ["b#{index}", {"number" => entry[:number], "blockedBy" => entry[:blocked_by]}]
    end
    {"data" => {"repository" => data}}
  end

  def connection(numbers, total: nil)
    {"totalCount" => total || numbers.length, "nodes" => numbers.map { |n| {"number" => n} }}
  end

  # 单次请求覆盖全部卡，且结果按编号正确归位。
  def test_single_batch_returns_dependencies_per_issue
    payload = batch_payload([
      {number: 1, blocked_by: connection([9])},
      {number: 2, blocked_by: connection([])},
      {number: 3, blocked_by: connection([1, 2])}
    ])
    gateway, runner = gateway_with(JSON.generate(payload))
    result = gateway.send(:fetch_blocked_by_batch, [1, 2, 3])

    assert_equal({1 => [9], 2 => [], 3 => [1, 2]}, result)
    assert_equal 1, runner.argvs.length, "三张卡必须合并成一次请求"
    joined = runner.argvs.first.join(" ")
    assert_includes joined, "b0: issue(number: 1)"
    assert_includes joined, "b2: issue(number: 3)"
  end

  # 超过批量上限时按批切分，不丢卡也不重复。
  def test_splits_into_batches_beyond_limit
    numbers = (1..(SebasAgents::GithubGateway::BLOCKED_BY_BATCH + 3)).to_a
    groups = numbers.each_slice(SebasAgents::GithubGateway::BLOCKED_BY_BATCH).to_a
    payloads = groups.map do |group|
      JSON.generate(batch_payload(group.map { |n| {number: n, blocked_by: connection([])} }))
    end
    gateway, runner = gateway_with(*payloads)
    result = gateway.send(:fetch_blocked_by_batch, numbers)

    assert_equal numbers.sort, result.keys.sort
    assert_equal 2, runner.argvs.length
    assert result.values.all? { |value| value.empty? }
  end

  # 别名指向的 issue 不存在/无权访问时节点为 null：必须拒绝，不能跳过。
  def test_missing_alias_node_rejects
    payload = {"data" => {"repository" => {
      "b0" => {"number" => 1, "blockedBy" => connection([])}
    }}}
    gateway, = gateway_with(JSON.generate(payload))
    error = assert_raises(SebasAgents::CommandError) do
      gateway.send(:fetch_blocked_by_batch, [1, 2])
    end
    assert_includes error.message, "缺 issue #2 节点"
  end

  # blockedBy 连接缺失/为 null：结构非法，不得当空集。
  def test_missing_connection_rejects
    payload = {"data" => {"repository" => {"b0" => {"number" => 1, "blockedBy" => nil}}}}
    gateway, = gateway_with(JSON.generate(payload))
    error = assert_raises(SebasAgents::CommandError) do
      gateway.send(:fetch_blocked_by_batch, [1])
    end
    assert_includes error.message, "blockedBy 连接结构非法"
  end

  # totalCount 超出 nodes 数量 = 被 first 截断：拒绝产出不完整依赖图。
  def test_truncated_dependencies_reject
    payload = batch_payload([{number: 1, blocked_by: connection([7], total: 150)}])
    gateway, = gateway_with(JSON.generate(payload))
    error = assert_raises(SebasAgents::CommandError) do
      gateway.send(:fetch_blocked_by_batch, [1])
    end
    assert_includes error.message, "被截断"
  end

  # totalCount 缺失/为 null/类型非法：to_i 会把它们静默变 0，
  # 于是空 nodes 看着像「没有前置」——必须显式拒绝。
  def test_missing_or_invalid_total_count_rejects
    [nil, "0", 0.0, -1].each do |total|
      connection = {"totalCount" => total, "nodes" => []}
      payload = {"data" => {"repository" => {"b0" => {"number" => 1, "blockedBy" => connection}}}}
      gateway, = gateway_with(JSON.generate(payload))
      error = assert_raises(SebasAgents::CommandError, "totalCount=#{total.inspect} 必须拒绝") do
        gateway.send(:fetch_blocked_by_batch, [1])
      end
      assert_includes error.message, "totalCount"
    end

    # 字段整体缺失同样拒绝。
    payload = {"data" => {"repository" => {"b0" => {"number" => 1, "blockedBy" => {"nodes" => []}}}}}
    gateway, = gateway_with(JSON.generate(payload))
    error = assert_raises(SebasAgents::CommandError) do
      gateway.send(:fetch_blocked_by_batch, [1])
    end
    assert_includes error.message, "totalCount"
  end

  # totalCount=0 + nodes=[] 是合法空结果，不能被上一条守卫误伤。
  def test_zero_total_with_empty_nodes_is_legal
    payload = batch_payload([{number: 1, blocked_by: connection([])}])
    gateway, = gateway_with(JSON.generate(payload))
    assert_equal({1 => []}, gateway.send(:fetch_blocked_by_batch, [1]))
  end

  # data.repository 缺失或为 null：结构非法，不得当成「全仓无前置」。
  def test_missing_repository_rejects
    [{"data" => {}}, {"data" => {"repository" => nil}}, {}].each do |payload|
      gateway, = gateway_with(JSON.generate(payload))
      error = assert_raises(SebasAgents::CommandError, payload.inspect) do
        gateway.send(:fetch_blocked_by_batch, [1])
      end
      assert_includes error.message, "缺 data.repository"
    end
  end

  # 返回编号与请求不符：别名错位会让依赖张冠李戴，必须拒绝。
  def test_alias_mismatch_rejects
    payload = {"data" => {"repository" => {
      "b0" => {"number" => 99, "blockedBy" => connection([])}
    }}}
    gateway, = gateway_with(JSON.generate(payload))
    error = assert_raises(SebasAgents::CommandError) do
      gateway.send(:fetch_blocked_by_batch, [1])
    end
    assert_includes error.message, "错位"
  end

  # GraphQL 部分成功（errors + data 并存）同样拒绝：不得消费不完整数据。
  def test_errors_with_data_rejects
    payload = batch_payload([{number: 1, blocked_by: connection([])}])
      .merge("errors" => [{"message" => "partial"}])
    gateway, = gateway_with(JSON.generate(payload))
    error = assert_raises(SebasAgents::CommandError) do
      gateway.send(:fetch_blocked_by_batch, [1])
    end
    assert_includes error.message, "批量查询失败"
  end

  # attach_blocked_by：只对带 Automation 块的卡发请求，其余保持空依赖。
  def test_attach_only_queries_automation_issues
    payload = batch_payload([{number: 4, blocked_by: connection([3])}])
    gateway, runner = gateway_with(JSON.generate(payload))
    issues = [
      SebasAgents::Model::Issue.from_hash(issue(4, body: automation)),
      SebasAgents::Model::Issue.from_hash(issue(5, body: "无自动化块"))
    ]
    result = gateway.send(:attach_blocked_by, issues)

    assert_equal [3], result.find { |item| item.number == 4 }.blocked_by
    assert_empty result.find { |item| item.number == 5 }.blocked_by
    refute_includes runner.argvs.first.join(" "), "issue(number: 5)",
      "没有 Automation 块的卡不该进批量查询"
  end

  # 批量结果写入单卡缓存：之后再取同一张卡不再走网络。
  def test_attach_seeds_single_card_cache
    payload = batch_payload([{number: 4, blocked_by: connection([3])}])
    gateway, runner = gateway_with(JSON.generate(payload))
    target = SebasAgents::Model::Issue.from_hash(issue(4, body: automation))
    gateway.send(:attach_blocked_by, [target])

    assert_equal [3], gateway.fetch_blocked_by(4)
    assert_equal 1, runner.argvs.length, "缓存命中后不应再发单卡请求"
  end
end
