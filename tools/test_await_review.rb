# frozen_string_literal: true

# tools/await_review.rb 的门闸语义测试。
#
# 这个脚本决定「三平台矩阵什么时候起跑」，它的失败模式与仓库其他工具相反：
# 其他工具 fail-closed（校验不过就拒），它必须 fail-open（拿不到审查结论就放行）。
# 一旦它变成 fail-closed，draft PR、审查方被卸载、按 path_filters 全跳过
# 都会把 PR 永久卡住，且表现为「必检缺失」这种难查的形态。
#
# 因此这里把「哪些情形必须放行」逐条钉成断言，不靠 workflow 注释约束。
# 真实网络与时钟都通过注入点替换：测试不联网、不 sleep。

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "await_review"

class AwaitReviewTest < Minitest::Test
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

  # --- 构造件 ---

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

  def run_with(pages)
    queue = pages.dup
    AwaitReview.gh_reader = lambda do |path|
      # 每个 PR 状态请求固定返回非 draft；check-runs 请求按队列推进。
      next({"draft" => false}) if path.include?("/pulls/")

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

  # --- 唯一「等」出来的路径 ---

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

  # --- 必须放行的情形（fail-open）---

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

  # --- 冒充与误判防范 ---

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

  # 完全没有 check run 时走「等出现」的宽限，不占用主超时。实测正常创建延迟
  # 18-23s、偶发 113s，5 分钟宽限足够；超过就认为审查方压根没打算审这个 PR。
  def test_absent_check_run_gives_up_at_appear_deadline
    stop_sleeping
    AwaitReview.clock = fake_clock(step: 10)

    assert_equal 0, run_with([runs_page([])] * 60)
    assert_includes @out.string, "未出现 coderabbitai"
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

  # 单次外部命令必须有硬超时，且超时必须真的杀得掉子进程。
  # 实测 Ruby 3.4.13：Timeout 包住 capture3 那种写法给 1s 超时仍跑满 6.01s
  # （capture3 在 ensure 里 join 子进程），所以断言实现用的是 popen2e + 进程组。
  def test_gh_call_has_hard_timeout
    assert_kind_of Integer, AwaitReview::GH_CALL_TIMEOUT_SECONDS
    assert_operator AwaitReview::GH_CALL_TIMEOUT_SECONDS, :<=, 120
    assert_operator AwaitReview::GH_CALL_TIMEOUT_SECONDS, :>, 0

    source = File.read(File.expand_path("await_review.rb", __dir__), encoding: "UTF-8")
    assert_includes source, "Timeout.timeout(GH_CALL_TIMEOUT_SECONDS)"
    assert_includes source, "pgroup: true", "必须用独立进程组，才能整组终止"
  end

  # 超时终止必须真的杀掉子进程，包括忽略 TERM 的后代。
  # 这条是行为级证据：用 `sh -c` 起一个忽略 TERM 的后代并记录其 PID，
  # 断言超时返回后该 PID 已消失。只断言耗时不够——`sh -c "sleep 10"` 可能被
  # shell 直接 exec 掉，没有后代可杀，测试就永远绿（CodeRabbit 在 PR #280 指出）。
  def test_hanging_command_is_actually_killed
    skip "需要 POSIX 进程组语义" if Gem.win_platform?

    dir = Dir.mktmpdir
    pid_file = File.join(dir, "descendant.pid")
    # 后代忽略 TERM 并常驻；外壳同样忽略 TERM，确保只有 KILL 能收场。
    script = <<~SH
      trap '' TERM
      sh -c 'trap "" TERM; echo $ > #{pid_file}; sleep 30' &
      wait
    SH

    original = AwaitReview::GH_CALL_TIMEOUT_SECONDS
    silence_warnings { AwaitReview.const_set(:GH_CALL_TIMEOUT_SECONDS, 1) }

    started = Time.now
    error = assert_raises(RuntimeError) do
      AwaitReview.run_command("sh", "-c", script)
    end
    elapsed = Time.now - started

    assert_includes error.message, "超时"
    assert_operator elapsed, :<, 10,
      "超时必须真的终止进程组；实测 #{elapsed.round(2)}s 说明还在等 sleep 30 自然退出"

    # 最多等 2s 让 /proc 语义的系统完成回收可见性
    deadline = Time.now + 2
    sleep 0.05 while descendant_alive?(pid_file) && Time.now < deadline
    refute descendant_alive?(pid_file),
      "忽略 TERM 的后代仍存活：说明只杀了组长，没有升级到 KILL 整组"
  ensure
    silence_warnings { AwaitReview.const_set(:GH_CALL_TIMEOUT_SECONDS, original) } if original
    cleanup_pid(pid_file)
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  def descendant_alive?(pid_file)
    pid = File.exist?(pid_file) ? File.read(pid_file).to_i : 0
    return false unless pid.positive?

    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def cleanup_pid(pid_file)
    return unless pid_file && File.exist?(pid_file)

    pid = File.read(pid_file).to_i
    Process.kill("KILL", pid) if pid.positive?
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def silence_warnings
    verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = verbose
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

  # --- 门闸本身不判质量 ---

  # conclusion=success 只代表审查流程跑完；有可修意见也照样放行，
  # 意见由 PR 评论与 review thread 承载。
  def test_success_is_not_a_quality_verdict
    stop_sleeping
    page = runs_page([check_run(status: "completed", conclusion: "success")])

    assert_equal 0, run_with([page])
    refute_includes @out.string, "fail-open"
  end

  def test_defaults_are_used_when_env_is_absent
    assert_equal "coderabbitai", AwaitReview::DEFAULT_APP_SLUG
    assert_equal "CodeRabbit", AwaitReview::DEFAULT_CHECK_NAME
    # 实测审查耗时 5-7 分钟（PR #230/#231/#237/#238），默认上限留一倍余量。
    assert_operator AwaitReview::DEFAULT_TIMEOUT_SECONDS, :>=, 600
    assert_operator AwaitReview::DEFAULT_POLL_SECONDS, :>=, 10
  end
end
