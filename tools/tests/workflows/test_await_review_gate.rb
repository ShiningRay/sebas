# frozen_string_literal: true

# 整改门闸：review 里的 actionable 计数决定矩阵跑不跑，以及门闸评论只发一条。
#
# 安全边界在这里：任何人都能发一条正文含 `Actionable comments posted: 99`
# 的 review，所以作者必须与 app_slug 对上，否则 PR 作者自己就能把门闸卡红
# （CWE-345）。

require_relative "../support/boot"
require_relative "../../await_review"
require_relative "../support/await_review_helpers"

class AwaitReviewGateTest < Minitest::Test
  include AwaitReviewHelpers

  def test_actionable_reviews_block_the_matrix
    stop_sleeping
    code = run_with([success_run], reviews: [actionable_review(count: 2)])

    assert_equal 1, code
    assert_includes @out.string, "2 条需整改项"
    assert_includes @out.string, "矩阵不跑"
  end

  def test_review_without_actionable_passes
    stop_sleeping
    code = run_with([success_run], reviews: [review(body: "已跳过某些文件")])

    assert_equal 0, code
    assert_includes @out.string, "未提出需整改项"
  end

  # 多条 review 的 actionable 求和：CodeRabbit 每轮可能只报一部分。
  def test_actionable_counts_are_summed
    stop_sleeping
    reviews = [actionable_review(count: 2), review(body: ""), actionable_review(count: 1)]

    assert_equal 1, run_with([success_run], reviews: reviews)
    assert_includes @out.string, "3 条需整改项"
  end

  # 只看当前 head：旧 commit 的意见不该挡住已修过的新 commit。
  def test_actionable_on_older_commit_is_ignored
    stop_sleeping
    stale = actionable_review(count: 5, commit: "b" * 40)

    assert_equal 0, run_with([success_run], reviews: [stale])
    assert_includes @out.string, "未提出需整改项"
  end

  # 安全：任何人都能发一条正文含 `Actionable comments posted: 99` 的 review，
  # 若不过滤作者，PR 作者自己就能把门闸永久卡红（CWE-345）。
  def test_forged_review_from_other_author_is_ignored
    stop_sleeping

    code = run_with([success_run], reviews: [forged_review(count: 99, author: "mallory")])
    assert_equal 0, code
    assert_includes @out.string, "未提出需整改项"
  end

  # 作者名带不带 [bot] 后缀都要认得出（GitHub App 身份写成 `<slug>[bot]`）。
  def test_bot_suffix_is_normalized
    assert AwaitReview.trusted_review_author?(
      {"user" => {"login" => "coderabbitai[bot]"}}, "coderabbitai"
    )
    refute AwaitReview.trusted_review_author?(
      {"user" => {"login" => "shiningray"}}, "coderabbitai"
    )
    refute AwaitReview.trusted_review_author?({"user" => nil}, "coderabbitai")
  end

  # reviews 必须翻页：接口按时间正序、单页 100 条，当前 head 的 review 可能在后页。
  # 只看首页会把「有整改」误判成「无整改」并放行。
  def test_reviews_are_paginated
    source = File.read(File.expand_path("../../await_review.rb", __dir__), encoding: "UTF-8")
    fetch = source[/def fetch_reviews\(.*?\n  end\n/m]
    refute_nil fetch, "应能定位 fetch_reviews"
    assert_includes fetch, "paginate: true", "fetch_reviews 必须翻页"
  end

  # 找旧评论失败时不能当成「没贴过」：那会重复发评论。
  def test_find_comment_raises_on_bad_shape
    AwaitReview.gh_reader = ->(_path) { {"not" => "an array"} }
    assert_raises(RuntimeError) { AwaitReview.find_comment("o/r", "1") }
  end

  # 审查没跑成时不读 actionable：那是 fail-open 的领地。
  def test_actionable_is_not_consulted_when_review_failed
    stop_sleeping
    failed = runs_page([check_run(status: "completed", conclusion: "cancelled")])

    assert_equal 0, run_with([failed], reviews: [actionable_review(count: 9)])
    assert_includes @out.string, "fail-open"
    refute_includes @out.string, "需整改项"
  end

  # 读 reviews 失败也必须放行：拿不到结论 ≠ 确认有问题。
  def test_unreadable_reviews_pass_open
    stop_sleeping
    AwaitReview.gh_reader = lambda do |path|
      raise "HTTP 500" if path.include?("/reviews")
      next({"draft" => false}) if path.match?(%r{/pulls/\d+\z})

      success_run
    end

    assert_equal 0, AwaitReview.run(env: env, out: @out)
    assert_includes @out.string, "fail-open"
  end

  # 评论只发一次：重跑更新同一条，避免刷屏。
  # 评论只发一次：重跑更新同一条，避免刷屏。
  def test_comment_is_updated_not_duplicated
    stop_sleeping
    writes = []
    AwaitReview.gh_writer = ->(method, path, payload) { writes << [method, path, payload] }

    existing = [{"id" => 42, "body" => "#{AwaitReview::COMMENT_MARKER}\n旧内容"}]
    AwaitReview.gh_reader = lambda do |path|
      # 顺序要紧：/issues/N/comments、/pulls/N/reviews 都要先于 PR 状态判断。
      next existing if path.include?("/comments")
      next [actionable_review] if path.include?("/reviews")
      next({"draft" => false}) if path.match?(%r{/pulls/\d+\z})

      success_run
    end
    AwaitReview.run(env: env, out: @out)

    assert_equal 1, writes.length, "应只写一次（更新既有评论）"
    assert_equal "PATCH", writes[0][0]
    assert_includes writes[0][1], "/issues/comments/42"
  ensure
    AwaitReview.gh_writer = nil
  end

  # 禁用评论时必须走完整个整改分支再断言「没写」。
  # 否则 check-run 队列已被前一次调用耗尽，第二次会连读 3 次失败直接 fail-open，
  # guard_actionable 根本没执行——删掉 GATE_COMMENT 判断这条仍会绿（假绿灯）。
  def test_comment_is_skipped_when_disabled
    stop_sleeping
    writes = []
    AwaitReview.gh_writer = ->(method, path, payload) { writes << [method, path, payload] }

    # 每次调用都重新供一轮完整响应：check run success + 整改 review。
    # 必须也覆盖 /comments（找旧评论），否则 find_comment 抛错、
    # post_block_comment 的 rescue 直接跳过，断言测不到「该发而未发」。
    with_reviews = lambda do |path|
      next [actionable_review] if path.include?("/reviews")
      next [{"id" => 1, "body" => AwaitReview::COMMENT_MARKER}] if path.include?("/comments")
      next({"draft" => false}) if path.match?(%r{/pulls/\d+\z})

      success_run
    end

    AwaitReview.gh_reader = with_reviews
    assert_equal 1, AwaitReview.run(env: env, out: @out), "默认应判整改"
    refute_empty writes, "默认应发评论"

    writes.clear
    @out = StringIO.new
    AwaitReview.gh_reader = with_reviews
    assert_equal 1, AwaitReview.run(env: env("GATE_COMMENT" => "false"), out: @out),
      "禁用评论不影响判定结果"
    assert_includes @out.string, "需整改项"
    assert_empty writes, "GATE_COMMENT=false 时不该贴评论"
  ensure
    AwaitReview.gh_writer = nil
  end

  def test_actionable_pattern_parses_counts
    assert_equal 3, AwaitReview::ACTIONABLE_PATTERN.match("Actionable comments posted: 3")[1].to_i
    assert_nil AwaitReview::ACTIONABLE_PATTERN.match("no actionable comments")
    assert_equal 0, AwaitReview::ACTIONABLE_PATTERN.match("Actionable comments posted: 0")[1].to_i
  end

  # 找旧评论必须翻页：PR 评论过百时旧评论落第二页，只看首页会重复发布。
  #
  # 不能对整份源码做字符串包含断言：`fetch_reviews` 里也有 `paginate: true`，
  # 只删掉 find_comment 的那一个仍然全绿。这里替掉最外层 run_command 捕获
  # 真实 argv，确认 find_comment 发出去的 gh 命令确实带 --paginate。
  def test_find_comment_paginates
    captured = []
    AwaitReview.singleton_class.alias_method(:__orig_run_command, :run_command)
    AwaitReview.define_singleton_method(:run_command) do |*command, **_opts|
      captured << command
      ["[]", Struct.new(:success?).new(true)]
    end

    begin
      assert_nil AwaitReview.find_comment("o/r", "1")
    ensure
      AwaitReview.singleton_class.alias_method(:run_command, :__orig_run_command)
      AwaitReview.singleton_class.send(:remove_method, :__orig_run_command)
    end

    assert_equal 1, captured.length, "find_comment 应只发一次（单页语义由 gh 展开）"
    assert_includes captured.first, "--paginate", "find_comment 的 gh 调用必须带 --paginate"
    assert(captured.first.any? { |arg| arg.include?("/issues/1/comments") },
      "必须查 PR 评论端点：#{captured.first.inspect}")
  end

  # conclusion=success 只代表审查流程跑完；有可修意见也照样放行，
  # 意见由 PR 评论与 review thread 承载。
  # success 只代表审查跑完；是否放行取决于 actionable 标记（见整改用例）。
  def test_success_without_actionable_passes_quietly
    stop_sleeping
    page = runs_page([check_run(status: "completed", conclusion: "success")])

    assert_equal 0, run_with([page])
    refute_includes @out.string, "fail-open"
    assert_includes @out.string, "未提出需整改项"
  end

  def test_defaults_are_used_when_env_is_absent
    assert_equal "coderabbitai", AwaitReview::DEFAULT_APP_SLUG
    assert_equal "CodeRabbit", AwaitReview::DEFAULT_CHECK_NAME
    # 实测审查耗时 5-7 分钟（PR #230/#231/#237/#238），默认上限留一倍余量。
    assert_operator AwaitReview::DEFAULT_TIMEOUT_SECONDS, :>=, 600
    assert_operator AwaitReview::DEFAULT_POLL_SECONDS, :>=, 10
  end

end
