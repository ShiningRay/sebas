# frozen_string_literal: true

# 快照读取的并发契约：顶层读取真并发、单流失败整体 fail-closed、
# 评论索引只预热一次且与 blocked_by 重叠。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class SnapshotConcurrencyTest < Minitest::Test
  include SnapshotHelpers

  # 每次调用都睡一小段，并统计同时在飞的峰值。
  # 串行实现峰值恒为 1；并发实现必然 ≥ 3。与机器快慢无关。
  class SleepyRunner
    attr_reader :peak, :paths

    def initialize(payloads, delay: 0.15)
      @payloads = payloads
      @delay = delay
      @in_flight = 0
      @peak = 0
      @paths = []
      @lock = Mutex.new
    end

    def json!(*argv)
      path = argv.find { |arg| arg.start_with?("repos/") } || "graphql"
      # 最长前缀优先：issues/comments 必须以它自己匹配，不能被 issues 抢走。
      key = @payloads.keys.sort_by { |candidate| -candidate.length }
        .find { |candidate| path.start_with?(candidate) }
      raise "未预期的请求：#{argv.join(" ")}" if key.nil?

      @lock.synchronize do
        @paths << key
        @in_flight += 1
        @peak = [@peak, @in_flight].max
      end
      sleep @delay
      JSON.parse(@payloads.fetch(key))
    ensure
      @lock.synchronize { @in_flight -= 1 }
    end
  end

  # REST issues 接口的形状：milestone/labels 都是对象数组，与 build_issue 一致。
  def raw_issue(number, body)
    {"number" => number, "title" => "issue #{number}", "state" => "OPEN",
     "body" => body, "labels" => [], "milestone" => {"number" => 2},
     "assignees" => [], "html_url" => "https://github.com/o/r/issues/#{number}"}
  end

  def payloads(issue_body: nil)
    {
      "repos/o/r/milestones" => JSON.generate([milestone(number: 2, order: 4, track: "main", open_issues: 0)]),
      "repos/o/r/issues" => JSON.generate([raw_issue(1, issue_body || automation)]),
      # 证据块默认引用 issuecomment-1，索引里给一条真实记录，
      # 避免走单条回退（那种路径由 SourceRefBulkTest 单独覆盖）。
      "repos/o/r/issues/comments" => JSON.generate([
        {"id" => 1, "user" => {"login" => "ShiningRay"}, "body" => "ok"}
      ]),
      "repos/o/r/commits/main" => JSON.generate({"sha" => "abc123"}),
      "graphql" => JSON.generate({"data" => {"repository" => {
        "b0" => {"number" => 1, "blockedBy" => {"totalCount" => 0, "nodes" => []}},
        "pullRequests" => {"pageInfo" => {"hasNextPage" => false}, "nodes" => []}
      }}})
    }
  end

  # 四条顶层读取必须真的并发：串行实现峰值只能是 1。
  def test_top_level_reads_run_concurrently
    runner = SleepyRunner.new(payloads)
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    snapshot = gateway.snapshot

    assert_operator runner.peak, :>=, 3,
      "并发峰值只有 #{runner.peak}（#{runner.paths.inspect}），顶层读取仍在串行"
    assert_equal "abc123", snapshot.main_sha
    assert_equal 1, snapshot.issues.length
    assert_equal 1, snapshot.milestones.length
  end

  # issue 流先失败、其他流仍在跑时，清理阶段不得用兄弟线程的异常顶替原始异常，
  # 也不得因某个已失败线程的 join 提前中断清理。
  def test_original_error_survives_cleanup_when_streams_fail_independently
    # issue 流立即失败并已终止；milestone 流稍晚失败但先于清理完成。
    # 旧实现的清理 `each { join }` 会在遇到已终止且带异常的线程时重抛，
    # 用它自己的异常顶替 issue 流的原始失败。
    double_failure = Class.new(SleepyRunner) do
      def json!(*argv)
        joined = argv.join(" ")
        if joined =~ %r{repos/o/r/issues(\?|$)}
          raise SebasAgents::CommandError.new("issue-stream-boom", command: argv)
        end
        if joined.include?("milestones")
          sleep 0.05
          raise SebasAgents::CommandError.new("milestone-stream-boom", command: argv)
        end

        super
      end
    end

    gateway = SebasAgents::GithubGateway.new(double_failure.new(payloads), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.snapshot }
    assert_includes error.message, "issue-stream-boom",
      "清理阶段不得用兄弟流的异常顶替原始失败（实际：#{error.message}）"
  end

  # 带 evidence 时必须预热评论索引；不带则一次都不该请求（避免白打 4 页）。
  def test_comment_index_preheated_only_when_evidence_present
    with_evidence = payloads(issue_body: automation + evidence(subject: "issue:1"))
    runner = SleepyRunner.new(with_evidence)
    SebasAgents::GithubGateway.new(runner, repo: "o/r").snapshot
    assert_includes runner.paths, "repos/o/r/issues/comments",
      "有 evidence 块时必须预热评论索引"

    plain_runner = SleepyRunner.new(payloads)
    SebasAgents::GithubGateway.new(plain_runner, repo: "o/r").snapshot
    refute_includes plain_runner.paths, "repos/o/r/issues/comments",
      "没有 evidence 块时不该请求评论索引"
  end

  # 评论索引与 blocked_by 必须在同一阶段重叠（都只依赖 issue 清单）。
  def test_comment_index_overlaps_blocked_by
    runner = SleepyRunner.new(payloads(issue_body: automation + evidence(subject: "issue:1")))
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    gateway.snapshot

    # 峰值已由时间重叠保证：评论索引与 blocked_by 都是 150ms 的慢请求，
    # 若串行则这两条不会同时出现在飞。
    assert_operator runner.peak, :>=, 3, "索引与 blocked_by 未并发（#{runner.paths.inspect}）"
    assert_includes runner.paths, "repos/o/r/issues/comments"
  end

  # 并发首次访问索引只能构建一次：否则会重复翻页并可能产出不一致快照。
  def test_comment_index_builds_once_under_concurrency
    calls = 0
    lock = Mutex.new
    runner = SleepyRunner.new(payloads(issue_body: automation + evidence(subject: "issue:1")))
    counting = Class.new(SleepyRunner) do
      define_method(:json!) do |*argv|
        if argv.join(" ").include?("issues/comments")
          lock.synchronize { calls += 1 }
        end
        super(*argv)
      end
    end

    gateway = SebasAgents::GithubGateway.new(counting.new(payloads(issue_body: automation + evidence(subject: "issue:1"))), repo: "o/r")
    threads = 4.times.map { Thread.new { gateway.send(:issue_comment_index) } }
    threads.each(&:value)

    assert_equal 1, calls, "并发首次访问必须只构建一次索引"
  end

  # 任一流失败都必须整体失败，不能返回半份快照。
  def test_stream_failure_fails_closed
    broken = Class.new(SleepyRunner) do
      def json!(*argv)
        raise SebasAgents::CommandError.new("boom", command: argv) if argv.join(" ").include?("commits/main")

        super
      end
    end
    gateway = SebasAgents::GithubGateway.new(broken.new(payloads), repo: "o/r")
    error = assert_raises(SebasAgents::CommandError) { gateway.snapshot }
    assert_includes error.message, "boom"
  end

end
