# frozen_string_literal: true

# tools/await_review.rb 的测试夹具。
#
# `AwaitReview` 的三处注入点（gh_reader / sleeper / clock）必须在每个用例前后清空：
# setup 与 teardown 都置 nil，避免上一个文件留下的桩串到下一个用例。
#
# run_with 让 gh_reader 先判 `/reviews` 再判 `/pulls/N`——两个路径都含 "/pulls/"，
# 顺序反了会把 review 请求喂成 `{"draft" => false}` 这种形状不符的哈希。
#
# fake_clock 是逻辑时钟，配合实现里「每轮取一次 now」得到确定性超时，
# 测试因此不 sleep 真实时间。


module AwaitReviewHelpers
  def setup
    AwaitReview.gh_reader = nil
    AwaitReview.sleeper = nil
    AwaitReview.clock = nil
    @out = StringIO.new
  end

  def teardown
    AwaitReview.gh_reader = nil
    AwaitReview.sleeper = nil
    AwaitReview.clock = nil
  end

  def env(overrides = {})
    {
      "REPO" => "o/r",
      "PR_NUMBER" => "1",
      "HEAD_SHA" => "a" * 40,
      "REVIEW_POLL_SECONDS" => "1",
      "REVIEW_APPEAR_SECONDS" => "20",
      "REVIEW_TIMEOUT_SECONDS" => "60"
    }.merge(overrides)
  end

  # reviews 默认空列表（= 无整改项）。测整改拦截时传 with_reviews。
  def run_with(pages, reviews: [])
    queue = pages.dup
    AwaitReview.gh_reader = lambda do |path|
      # /pulls/N/reviews 也含 "/pulls/"，必须先判 reviews，
      # 否则 review 请求会拿到 {"draft"=>false} 这种形状不符的哈希。
      next reviews if path.include?("/reviews")
      next({"draft" => false}) if path.match?(%r{/pulls/\d+\z})

      page = queue.shift
      raise "测试数据用尽：#{path}" if page.nil?

      page
    end
    AwaitReview.run(env: env, out: @out)
  end

  # 逻辑时钟：每次调用前进固定秒数，配合默认的「每轮取一次 now」实现确定性超时。
  def fake_clock(start: 0, step: 1)
    ticks = start
    lambda do
      ticks += step
      ticks
    end
  end

  def stop_sleeping
    @slept = 0
    AwaitReview.sleeper = ->(seconds) { @slept += seconds }
  end

  def runs_page(runs)
    {"check_runs" => runs}
  end

  def check_run(status:, conclusion: nil, name: "CodeRabbit", slug: "coderabbitai", started_at: "2026-01-01T00:00:00Z")
    {"name" => name, "status" => status, "conclusion" => conclusion,
     "app" => slug.nil? ? nil : {"slug" => slug}, "started_at" => started_at}
  end

  # 默认 author 写成审查方：门闸只认 app_slug 对应的作者（防伪造）。
  def review(commit: "a" * 40, body: "", author: "coderabbitai[bot]")
    {
      "commit_id" => commit,
      "body" => body,
      "state" => "COMMENTED",
      "user" => {"login" => author}
    }
  end

  # 伪造者：正文写得一模一样，但作者是别人。
  def forged_review(count: 9, author: "mallory")
    review(body: "**Actionable comments posted: #{count}**", author: author)
  end

  def actionable_review(count: 2, commit: "a" * 40)
    review(commit: commit, body: "**Actionable comments posted: #{count}**\n\n详情")
  end

  def success_run
    runs_page([check_run(status: "completed", conclusion: "success")])
  end

end
