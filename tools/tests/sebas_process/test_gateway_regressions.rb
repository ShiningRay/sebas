# frozen_string_literal: true

# Gateway 缺陷回归（阻断 6/7、应修 1）：GraphQL 错误体、分页错误体、
# PENDING 状态上下文不得判绿。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class GatewayRegressionTest < Minitest::Test
  # 阻断 6：GraphQL 出错不得当成无 thread
  def test_graphql_error_is_not_empty_threads
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    runner.define_singleton_method(:json!) { |*_args| {"errors" => [{"message" => "boom"}]} }
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_review_threads, 5) }
    assert_includes error.message, "reviewThreads"
  end

  def test_graphql_null_data_is_not_empty_threads
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    runner.define_singleton_method(:json!) { |*_args| {"data" => {"repository" => nil}} }
    assert_raises(SebasAgents::CommandError) { gateway.send(:fetch_review_threads, 5) }
  end

  # 阻断 7：分页返回错误体不得变成空列表
  def test_pagination_error_body_raises
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    runner.define_singleton_method(:json!) { |*_args| {"message" => "Bad credentials"} }
    assert_raises(SebasAgents::CommandError) { gateway.send(:paginate, "repos/o/r/issues") }
  end

  # 应修 1：StatusContext PENDING 不得判绿
  def test_pending_status_context_is_not_green
    runner = SebasAgents::CommandRunner.new(dry_run: false)
    gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
    checks = gateway.send(:normalize_checks, [{"context" => "ci", "state" => "PENDING"}])
    pr = SebasAgents::Model::PullRequest.from_hash("number" => 1, "checks" => checks)
    refute pr.checks_green?
  end
end
