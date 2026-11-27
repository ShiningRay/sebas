# frozen_string_literal: true

# evidence source_ref 的全量评论索引（PR2）。
# 每个 ref 原本 author + body 各一次请求；改全量分页后必须保证
# 「索引未命中」不会退化成空正文——空正文会让 Evidence 校验只验作者。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class SourceRefBulkTest < Minitest::Test
  include GatewayStubs

  def gateway_with(*responses)
    runner = GatewayStubs::SequenceRunner.new(responses)
    [SebasAgents::GithubGateway.new(runner, repo: "o/r"), runner]
  end

  def comment(id, login: "ShiningRay", body: "LGTM")
    {"id" => id, "user" => {"login" => login}, "body" => body}
  end

  def page_of(*comments)
    JSON.generate(comments)
  end

  def ref_for(id)
    "https://github.com/o/r/issues/1#issuecomment-#{id}"
  end

  # 命中索引：作者与正文都从一次全量分页里取，不发单条请求。
  def test_hit_uses_index_without_per_ref_requests
    gateway, runner = gateway_with(page_of(comment(11, body: "登记结论")))
    assert_equal "登记结论", gateway.send(:ref_body, ref_for(11))
    assert_equal "ShiningRay", gateway.send(:ref_author, ref_for(11))

    assert_equal 1, runner.argvs.length, "作者与正文必须复用同一份索引"
    assert_includes runner.argvs.first.join(" "), "issues/comments?per_page=100&page=1"
  end

  # 多个 ref 命中索引：仍然只请求一次分页。
  def test_multiple_refs_share_one_index_fetch
    gateway, runner = gateway_with(page_of(comment(11), comment(12)))
    gateway.send(:ref_body, ref_for(11))
    gateway.send(:ref_body, ref_for(12))

    assert_equal 1, runner.argvs.length
    assert_equal 2, gateway.instance_variable_get(:@issue_comment_index).length
  end

  # 索引未命中必须回退单条请求，不能返回空正文（否则 Evidence 只验作者 = fail-open）。
  def test_miss_falls_back_to_single_request
    gateway, runner = gateway_with(page_of, JSON.generate({"body" => "单条取回的正文"}))
    assert_equal "单条取回的正文", gateway.send(:ref_body, ref_for(77))

    assert_equal 2, runner.argvs.length
    assert_includes runner.argvs.last.join(" "), "issues/comments/77"
  end

  # 索引未命中时作者同样回退单条。
  def test_miss_author_falls_back
    gateway, runner = gateway_with(page_of, JSON.generate({"user" => {"login" => "fallback-user"}}))
    assert_equal "fallback-user", gateway.send(:ref_author, ref_for(88))
    assert_includes runner.argvs.last.join(" "), "issues/comments/88"
  end

  # 分页：满页继续翻，短页即止。
  def test_paginates_until_short_page
    full = JSON.generate(Array.new(SebasAgents::GithubGateway::PAGE_SIZE) { |i| comment(i + 1) })
    tail = page_of(comment(999))
    gateway, runner = gateway_with(full, tail)

    index = gateway.send(:issue_comment_index)
    assert_equal SebasAgents::GithubGateway::PAGE_SIZE + 1, index.length
    assert index.key?(999)
    assert_equal 2, runner.argvs.length
    assert_includes runner.argvs.last.join(" "), "page=2"
  end

  # 分页接口返回非数组：拒绝，不当成空索引。
  def test_non_array_page_rejects
    gateway, = gateway_with(JSON.generate({"message" => "Not Found"}))
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:issue_comment_index) }
    assert_includes error.message, "非数组"
  end

  # 评论缺 id：结构非法，不能静默跳过（跳过会让该 ref 变「未命中」，掩盖数据问题）。
  def test_comment_without_id_rejects
    gateway, = gateway_with(page_of({"user" => {"login" => "x"}, "body" => "y"}))
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:issue_comment_index) }
    assert_includes error.message, "缺 id"
  end

  # 索引里命中但缺 user.login：拒绝，不能当「无人登记」放过。
  def test_indexed_comment_without_author_rejects
    gateway, = gateway_with(page_of({"id" => 11, "body" => "x"}))
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:ref_author, ref_for(11)) }
    assert_includes error.message, "缺 user.login"
  end

  # 命中记录缺 body / body 非字符串：拒绝，不能 to_s 成空白当正文。
  def test_indexed_comment_without_body_rejects
    [{"id" => 11, "user" => {"login" => "ShiningRay"}},
     {"id" => 11, "user" => {"login" => "ShiningRay"}, "body" => nil},
     {"id" => 11, "user" => {"login" => "ShiningRay"}, "body" => 123}].each do |record|
      gateway, = gateway_with(page_of(record))
      error = assert_raises(SebasAgents::CommandError, record.inspect) do
        gateway.send(:ref_body, ref_for(11))
      end
      assert_includes error.message, "body"
    end
  end

  # 合法的空字符串正文照常放行（评论内容本身可以为空）。
  def test_indexed_empty_body_is_legal
    gateway, = gateway_with(page_of(comment(11, body: "")))
    assert_equal "", gateway.send(:ref_body, ref_for(11))
  end

  # 无限满页：到上限即拒绝，不无休止翻页。
  def test_runaway_pagination_rejects
    full = JSON.generate(Array.new(SebasAgents::GithubGateway::PAGE_SIZE) { |i| comment(i + 1) })
    responses = Array.new(SebasAgents::GithubGateway::MAX_PAGES, full)
    gateway, = gateway_with(*responses)
    error = assert_raises(SebasAgents::CommandError) { gateway.send(:issue_comment_index) }
    assert_includes error.message, "分页超过"
  end

  # resolve_bodies / resolve_authors 共用一次索引：49 个 ref 的场景等价于 1 次分页。
  def test_resolve_wrappers_share_index
    blocks = [{"source_ref" => ref_for(11)}, {"source_ref" => ref_for(12)}]
    gateway, runner = gateway_with(page_of(comment(11, body: "a"), comment(12, body: "b")))

    bodies = gateway.send(:resolve_bodies, blocks)
    authors = gateway.send(:resolve_authors, blocks)

    assert_equal({"https://github.com/o/r/issues/1#issuecomment-11" => "a",
                  "https://github.com/o/r/issues/1#issuecomment-12" => "b"}, bodies)
    assert_equal %w[ShiningRay ShiningRay], authors.values
    assert_equal 1, runner.argvs.length
  end

end
