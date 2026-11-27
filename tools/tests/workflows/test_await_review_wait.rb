# frozen_string_literal: true

# 等待与放行：唯一「等出来」的路径，以及所有必须 fail-open 的情形。
#
# await_review 的失败方向与仓库其他工具相反——拿不到审查结论就放行。
# 一旦它变成 fail-closed，draft PR、审查方被卸载、path_filters 全跳过
# 都会把 PR 永久卡住，且表现为「必检缺失」这种难查的形态。

require_relative "../support/boot"
require_relative "../../await_review"
require_relative "../support/await_review_helpers"

class AwaitReviewWaitTest < Minitest::Test
  include AwaitReviewHelpers

  def test_waits_until_review_completes
    stop_sleeping
    AwaitReview.clock = fake_clock
    page_in_progress = runs_page([check_run(status: "in_progress")])
    done = runs_page([check_run(status: "completed", conclusion: "success")])

    assert_equal 0, run_with([page_in_progress, page_in_progress, done])
    assert_includes @out.string, "等待 CodeRabbit 完成"
    assert_includes @out.string, "审查已完成"
    refute_includes @out.string, "fail-open", "正常路径不应触发放行"
  end

  def test_draft_pr_passes_without_polling
    stop_sleeping
    AwaitReview.gh_reader = lambda do |path|
      next {"draft" => true} if path.include?("/pulls/")

      flunk "draft PR 不应去读 check-runs"
    end

    assert_equal 0, AwaitReview.run(env: env, out: @out)
    assert_includes @out.string, "draft"
    assert_includes @out.string, "fail-open"
  end

  def test_timeout_passes_open
    stop_sleeping
    AwaitReview.clock = fake_clock(step: 10)
    page = runs_page([check_run(status: "in_progress")])

    assert_equal 0, run_with([page] * 20)
    assert_includes @out.string, "超时"
    assert_includes @out.string, "fail-open"
  end

  # 完全没有 check run 时走「等出现」的宽限，不占用主超时。
  # 实测正常创建延迟 18-23s、偶发 113s，5 分钟宽限足够；超过就认为审查方
  # 压根没打算审这个 PR（path_filters 全排除 / App 未启用）。
  def test_absent_check_run_gives_up_at_appear_deadline
    stop_sleeping
    AwaitReview.clock = fake_clock(step: 10)

    assert_equal 0, run_with([runs_page([])] * 60)
    assert_includes @out.string, "未出现 coderabbitai"
    assert_includes @out.string, "不在审查范围内"
  end

  # 审查方给出 failure / cancelled / skipped 都表示「这一轮没审成」，不是「审出问题」。
  # 若在这里拦 PR，等于把审查方的不稳定变成合并门禁的不稳定。
  def test_non_success_conclusion_passes_open
    %w[failure cancelled timed_out skipped].each do |conclusion|
      @out = StringIO.new
      stop_sleeping
      page = runs_page([check_run(status: "completed", conclusion: conclusion)])

      assert_equal 0, run_with([page]), "conclusion=#{conclusion} 应放行"
      assert_includes @out.string, "fail-open"
      assert_includes @out.string, conclusion
    end
  end

  def test_repeated_api_errors_pass_open
    stop_sleeping
    AwaitReview.gh_reader = lambda do |path|
      next({"draft" => false}) if path.include?("/pulls/")

      raise RuntimeError, "HTTP 500"
    end

    assert_equal 0, AwaitReview.run(env: env, out: @out)
    assert_includes @out.string, "连续 3 次"
    assert_includes @out.string, "fail-open"
  end

  def test_pr_state_failure_passes_open
    stop_sleeping
    AwaitReview.gh_reader = ->(_path) { raise RuntimeError, "HTTP 404" }

    assert_equal 0, AwaitReview.run(env: env, out: @out)
    assert_includes @out.string, "fail-open"
  end

  def test_missing_env_passes_open
    AwaitReview.run(env: {}, out: @out)
    assert_includes @out.string, "fail-open"
  end

  # 同名但不同 app 的 check run 不算审查结果：PR 可以提交一个叫 CodeRabbit 的
  # check run 把自己「审」成 success。
  def test_check_run_from_other_app_is_ignored
    stop_sleeping
    AwaitReview.clock = fake_clock(step: 10)
    impostor = runs_page([check_run(status: "completed", conclusion: "success", slug: "evil-app")])

    assert_equal 0, run_with([impostor] * 40)
    assert_includes @out.string, "尚未出现 coderabbitai"
    assert_includes @out.string, "不在审查范围内"
  end

  # 出现但一直不完成，必须等到主超时——否则「审查慢」会被当成「不在审查范围」。
  def test_pending_check_run_waits_for_main_timeout
    stop_sleeping
    AwaitReview.clock = fake_clock(step: 10)
    page = runs_page([check_run(status: "in_progress")])

    assert_equal 0, run_with([page] * 200)
    assert_includes @out.string, "超时 60s", "应等到主超时，而不是「等出现」的宽限"
    refute_includes @out.string, "不在审查范围内"
  end

  # 审查进行中遇到接口错误，不能退回「等出现」的口径直接放行
  # （CodeRabbit 在 PR #280 指出：第 280s 读到 in_progress、第 320s 读失败时，
  # 旧实现把 runs 置空后按已过期的 appear_deadline 放行，矩阵在审查未完时起跑）。
  def test_api_error_after_seen_does_not_fall_back_to_appear_window
    stop_sleeping
    AwaitReview.clock = fake_clock(step: 10)

    in_progress = runs_page([check_run(status: "in_progress")])
    done = runs_page([check_run(status: "completed", conclusion: "success")])
    script = [in_progress] * 4 + [RuntimeError.new("HTTP 502"), in_progress, done]

    queue = script.dup
    AwaitReview.gh_reader = lambda do |path|
      next({"draft" => false}) if path.include?("/pulls/")

      page = queue.shift
      raise page if page.is_a?(RuntimeError)

      raise "测试数据用尽" if page.nil?

      page
    end

    # 主上限放宽到 200s，才能在逻辑时钟推进下走到「读完」那一步；
    # 关键断言是它没有在 20s 的 appear 窗一到就放行。
    assert_equal 0, AwaitReview.run(env: env("REVIEW_TIMEOUT_SECONDS" => "200"), out: @out)
    refute_includes @out.string, "不在审查范围内"
    assert_includes @out.string, "审查已完成"
  end

  # app 为 null 的 check run 不能让脚本崩溃（旧实现用 dig 会 TypeError）。
  def test_null_app_does_not_crash
    stop_sleeping
    AwaitReview.clock = fake_clock(step: 10)
    page = runs_page([check_run(status: "completed", conclusion: "success", slug: nil)])

    assert_equal 0, run_with([page] * 20)
    assert_includes @out.string, "尚未出现 coderabbitai"
  end

  # 同一 sha 重跑会留下多条同名 check run，必须按开始时间取最新一条，
  # 否则早先的 success 会让新一轮审查被当成已完成。
  def test_latest_check_run_wins
    stop_sleeping
    stale = check_run(status: "completed", conclusion: "success", started_at: "2026-01-01T00:00:00Z")
    fresh = check_run(status: "in_progress", started_at: "2026-01-01T01:00:00Z")
    done = check_run(status: "completed", conclusion: "cancelled", started_at: "2026-01-01T01:00:00Z")

    AwaitReview.clock = fake_clock
    assert_equal 0, run_with([runs_page([stale, fresh]), runs_page([stale, done])])
    assert_includes @out.string, "cancelled", "应以最新那条为准，而不是旧的 success"
  end

end
