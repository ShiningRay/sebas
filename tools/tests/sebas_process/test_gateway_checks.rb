# frozen_string_literal: true

# checks 的两段式读取（PR4）：PR 清单不再带 statusCheckRollup，open PR 与
# verify merge 点头名的 PR 单独取，且必须绑定 head——否则会把新提交的绿灯
# 安到旧 head 上，产出混合快照。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class ChecksLoadingTest < Minitest::Test
  include GatewayStubs
  include SnapshotHelpers

  # fetch_checks 的响应形状：单个别名 p，内含 statusCheckRollup。
  def rollup_payload(number, nodes:, has_next:, drop_page_info: false, head: nil)
    contexts = {"nodes" => nodes}
    contexts["pageInfo"] = {"hasNextPage" => has_next} unless drop_page_info
    node = {"number" => number, "statusCheckRollup" => {"contexts" => contexts}}
    node["headRefOid"] = head unless head.nil?
    {"data" => {"repository" => {"p" => node}}}
  end

  def page(nodes, has_next, cursor)
    info = { "hasNextPage" => has_next }
    info["endCursor"] = cursor unless cursor.nil?
    { "data" => { "repository" => { "pullRequests" => {
      "nodes" => nodes,
      "pageInfo" => info
    } } } }
  end

  # CLI 层：verify merge 必须让 gateway 补取目标 PR 的 checks。
  # 否则两段式下 checks 恒为「未取」，合并后核验退化成永远 unverified。
  class ChecksLoadingCliTest < Minitest::Test
    include SnapshotHelpers

    # 记录 snapshot 的入参，再交给真实实现：只断言「有没有传 verified_pr」，
    # 不 monkey patch 生产类。
    class RecordingCli < SebasAgents::CLI
      attr_reader :snapshot_options

      private

      def snapshot(options, proposal_issue: nil, verified_pr: nil)
        @snapshot_options = {proposal_issue: proposal_issue, verified_pr: verified_pr}
        super
      end
    end

    # 在线路径：不带 --snapshot，走真实 GithubGateway。断言目标 PR 真的发起了
    # checks 查询——只断言参数传下去的话，删掉 gateway 的 attach_checks 分支
    # 用例仍会通过。
    class PathRunner < SebasAgents::CommandRunner
      attr_reader :seen

      def initialize(payloads)
        super(dry_run: true)
        @payloads = payloads
        @seen = []
        @lock = Mutex.new
      end

      def json!(*argv, chdir: Dir.pwd)
        joined = argv.join(" ")
        @lock.synchronize { @seen << joined }
        key = @payloads.keys.find { |candidate| joined.include?(candidate) }
        raise "未预期的请求：#{joined}" if key.nil?

        JSON.parse(@payloads.fetch(key))
      end
    end

    class OnlineCli < SebasAgents::CLI
      attr_reader :runner

      def initialize(runner:, **kw)
        super(**kw)
        @runner = runner
      end

      private

      def runner(_options)
        @runner
      end
    end

    def online_payloads
      {
        "milestones" => JSON.generate([milestone(number: 2, order: 4, track: "main", open_issues: 0)]),
        "issues/comments" => JSON.generate([]),
        "repos/o/r/issues?state=all" => JSON.generate([]),
        "commits/main" => JSON.generate({"sha" => "abc123"}),
        "blockedBy" => JSON.generate({"data" => {"repository" => {}}}),
        "statusCheckRollup" => JSON.generate({"data" => {"repository" => {"p" => {
          "number" => 10, "headRefOid" => "sha10",
          "statusCheckRollup" => {"contexts" => {
            "pageInfo" => {"hasNextPage" => false},
            "nodes" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]
          }}
        }}}}),
        "pullRequests" => JSON.generate({"data" => {"repository" => {"pullRequests" => {
          "pageInfo" => {"hasNextPage" => false},
          "nodes" => [{"number" => 10, "state" => "MERGED", "headRefName" => "f", "baseRefName" => "main",
                       "headRefOid" => "sha10", "mergeStateStatus" => "CLEAN", "url" => "u",
                       "isCrossRepository" => false,
                       "closingIssuesReferences" => {"pageInfo" => {"hasNextPage" => false},
                                                     "nodes" => [{"number" => 10}]}}]
        }}}})
      }
    end

    def test_verify_merge_over_network_loads_target_pr_checks
      runner = PathRunner.new(online_payloads)
      cli = OnlineCli.new(runner: runner, out: StringIO.new, err: StringIO.new)
      out = StringIO.new
      cli.instance_variable_set(:@out, out)
      cli.run(["verify", "merge", "10", "10", "--repo", "o/r"])

      checks_calls = runner.seen.select { |call| call.include?("statusCheckRollup") }
      assert(checks_calls.any? { |call| call.include?("number: 10") },
        "必须对目标 PR #10 发起 checks 查询（实际：#{runner.seen.inspect}）")
    end

    def test_verify_merge_requests_target_pr_checks
      data = snapshot(
        issues: [issue(10, body: automation, state: "CLOSED", state_reason: "COMPLETED")],
        pull_requests: [{"number" => 10, "state" => "MERGED", "closing_issues" => [10],
                         "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}]}]
      )
      Dir.mktmpdir do |dir|
        path = File.join(dir, "s.json")
        File.write(path, JSON.generate(data), encoding: "UTF-8")
        cli = RecordingCli.new(out: StringIO.new, err: StringIO.new)
        cli.run(["verify", "merge", "10", "10", "--snapshot", path])
        assert_equal 10, cli.snapshot_options[:verified_pr],
          "verify merge 必须请求补取目标 PR 的 checks"
      end
    end
  end

  # 列表形状：两段式后不再带 statusCheckRollup（PR4），只有 rolling 单独取。
  def pr_node(number:, cross: false, closing_truncated: false, drop_cross: false)
    {
      "number" => number, "state" => "MERGED",
      "headRefName" => "feat/#{number}", "baseRefName" => "main",
      "headRefOid" => "sha#{number}", "mergeStateStatus" => "CLEAN",
      "url" => "https://example.test/pr/#{number}",
      "closingIssuesReferences" => {
        "pageInfo" => { "hasNextPage" => closing_truncated },
        "nodes" => closing_truncated ? Array.new(10) { |i| { "number" => i } } : []
      }
    }.tap do |node|
      node["isCrossRepository"] = cross unless drop_cross
    end
  end

  # attach_checks：给点名 PR 补取 checks；不在快照里必须拒绝。
  def test_attach_checks_loads_named_pr
    rollup = JSON.generate(rollup_payload(1, head: "sha1",
      nodes: [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}], has_next: false))
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([rollup]), repo: "o/r")
    pr = SebasAgents::Model::PullRequest.from_hash({"number" => 1, "state" => "MERGED", "head_sha" => "sha1"})
    loaded = gateway.send(:attach_checks, [pr], [1]).first
    assert loaded.checks_loaded?
    assert_equal ["spec"], loaded.checks.map { |c| c["name"] }
  end

  # checks 属于另一个 head：必须拒绝，不能拼成混合快照。
  def test_attach_checks_rejects_head_advance
    rollup = JSON.generate(rollup_payload(1, head: "new-sha", nodes: [], has_next: false))
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([rollup]), repo: "o/r")
    pr = SebasAgents::Model::PullRequest.from_hash({"number" => 1, "state" => "MERGED", "head_sha" => "old-sha"})
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:attach_checks, [pr], [1]) }
    assert_includes error.message, "混合快照"
  end

  # 回读缺 headRefOid 且要求绑定 head：拒绝，不猜。
  def test_fetch_checks_requires_head_when_expected
    payload = JSON.generate(rollup_payload(1, nodes: [], has_next: false))
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([payload]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) do
      gateway.send(:fetch_checks, 1, expected_head: "sha1")
    end
    assert_includes error.message, "缺 headRefOid"
  end

  def test_attach_checks_rejects_unknown_pr
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([]), repo: "o/r")
    pr = SebasAgents::Model::PullRequest.from_hash({"number" => 1, "state" => "MERGED"})
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:attach_checks, [pr], [9]) }
    assert_includes error.message, "不在快照内"
  end

  # 列表不再带 rollup：merged PR 的 checks 为 nil（未取），不是空集。
  def test_merged_pr_checks_are_not_loaded
    gateway = SebasAgents::GithubGateway.new(
      GatewayStubs::SequenceRunner.new([JSON.generate(page([pr_node(number: 1)], false, nil))]), repo: "o/r"
    )
    pr = gateway.send(:fetch_pull_requests).first
    refute pr.checks_loaded?, "merged PR 不取 rollup，必须是未取状态"
  end

  # open PR 必须补取 checks，且绑定到列表记录的 head：
  # 不传 expected_head 就会把新提交的绿灯安到旧 head 上。
  def test_open_pr_checks_are_loaded_with_head_binding
    open_node = pr_node(number: 1).merge("state" => "OPEN")
    open_node.delete("statusCheckRollup")
    list_payload = page([open_node], false, nil)
    checks_payload = rollup_payload(1, head: "sha1", nodes: [
      {"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}
    ], has_next: false)
    review_payload = {"data" => {"repository" => {"pullRequest" => {
      "reviewThreads" => {"nodes" => [], "pageInfo" => {"hasNextPage" => false}}
    }}}}
    details_payload = '{"body": "b", "head_sha": "sha1"}'
    files_payload = "[]"

    # 调用顺序：list → reviewThreads → prDetail → files → prDetail → checks
    gateway = SebasAgents::GithubGateway.new(
      GatewayStubs::SequenceRunner.new([JSON.generate(list_payload), JSON.generate(review_payload),
        details_payload, files_payload, details_payload, JSON.generate(checks_payload)]),
      repo: "o/r"
    )
    pr = gateway.send(:fetch_pull_requests).first

    assert pr.checks_loaded?, "open PR 必须取回 checks"
    assert_equal ["spec"], pr.checks.map { |c| c["name"] }
  end

  # open PR 的 checks 若来自另一个 head：整体拒绝，不产出混合快照。
  def test_open_pr_checks_head_mismatch_rejects
    open_node = pr_node(number: 1).merge("state" => "OPEN")
    open_node.delete("statusCheckRollup")
    list_payload = page([open_node], false, nil)
    checks_payload = rollup_payload(1, head: "OTHER", nodes: [], has_next: false)
    review_payload = {"data" => {"repository" => {"pullRequest" => {
      "reviewThreads" => {"nodes" => [], "pageInfo" => {"hasNextPage" => false}}
    }}}}
    details_payload = '{"body": "b", "head_sha": "sha1"}'

    gateway = SebasAgents::GithubGateway.new(
      GatewayStubs::SequenceRunner.new([JSON.generate(list_payload), JSON.generate(review_payload),
        details_payload, "[]", details_payload, JSON.generate(checks_payload)]),
      repo: "o/r"
    )
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_pull_requests) }
    assert_includes error.message, "混合快照"
  end

  # rollup 校验点已随两段式迁到 fetch_checks：列表不再带 rollup，
  # 只有 open PR 与点名 PR 单独取，截断同样必须拒绝。
  def test_truncated_rollup_contexts_reject
    payload = rollup_payload(1, nodes: [{}, {}], has_next: true)
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_checks, 1) }
    assert_includes error.message, "contexts 超过 100 条"
  end

  # round 3：rollup 的 contexts 必须有合法 pageInfo（缺失/字符串布尔都拒绝）。
  # 校验点随两段式迁到 fetch_checks。
  def test_inner_page_info_missing_rejects
    payload = rollup_payload(1, nodes: [], has_next: nil, drop_page_info: true)
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_checks, 1) }
    assert_includes error.message, "statusCheckRollup 结构非法"
  end

  def test_inner_page_info_non_boolean_rejects
    payload = rollup_payload(1, nodes: [], has_next: "true")
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_checks, 1) }
    assert_includes error.message, "statusCheckRollup 结构非法"
  end

  # statusCheckRollup=null 合法（检查未产出，非结构非法）
  def test_null_rollup_is_legal_empty_checks
    payload = {"data" => {"repository" => {"p" => {"number" => 1, "statusCheckRollup" => nil}}}}
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload)]), repo: "o/r")
    assert_empty gateway.send(:fetch_checks, 1)
  end

  # round 4：字段缺失 ≠ 显式 null——单 PR 查询缺 statusCheckRollup 是结构非法
  def test_missing_rollup_key_rejects
    payload = {"data" => {"repository" => {"p" => {"number" => 1}}}}
    gateway = SebasAgents::GithubGateway.new(GatewayStubs::SequenceRunner.new([JSON.generate(payload)]), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_checks, 1) }
    assert_includes error.message, "statusCheckRollup 结构非法"
  end

end
