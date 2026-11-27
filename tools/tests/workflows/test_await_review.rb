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

require_relative "../support/boot"
require_relative "../../await_review"

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

    source = File.read(File.expand_path("../../await_review.rb", __dir__), encoding: "UTF-8")
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
    #
    # 必须避开 heredoc 插值坑：曾写成插值 heredoc 并把 `$$` 写丢成 `$`，于是
    # PID 文件内容为字面 `$`、to_i 得 0、存活断言恒假通过（PR #280）。这里用
    # 单引号 heredoc（Ruby 不插值 `$`）+ 位置参数：PID 由 shell 自己展开，
    # 路径经 Shellwords 转义传入。
    script = format(<<~'SH', Shellwords.escape(pid_file))
      trap '' TERM
      sh -c 'trap "" TERM; echo $$ > "$1"; sleep 30' _ %s &
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

    # 先确认后代真的写了合法 PID：否则下面的「已消失」断言会空泛通过。
    assert File.exist?(pid_file), "后代没有写出 PID 文件，脚本未被真正执行"
    recorded = File.read(pid_file).strip
    assert_match(/\A\d+\z/, recorded, "PID 文件内容非法（应为纯数字）：#{recorded.inspect}")
    assert_operator recorded.to_i, :>, 0, "PID 必须为正数，实际 #{recorded.inspect}"

    # 最多等 2s 让进程退出在系统层面可见
    deadline = Time.now + 2
    sleep 0.05 while alive?(recorded.to_i) && Time.now < deadline
    refute alive?(recorded.to_i),
      "忽略 TERM 的后代（pid #{recorded}）仍存活：说明只杀了组长，没有升级到 KILL 整组"
  ensure
    silence_warnings { AwaitReview.const_set(:GH_CALL_TIMEOUT_SECONDS, original) } if original
    cleanup_pid(pid_file)
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end

  def alive?(pid)
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

  # --- 审查提出整改时挡住矩阵 ---

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
  # gh_reader 是测试桩看不出参数化行为，所以同时钉住源码里的 --paginate。
  def test_find_comment_paginates
    source = File.read(File.expand_path("../../await_review.rb", __dir__), encoding: "UTF-8")
    assert_includes source, "paginate: true", "find_comment 必须传 paginate: true"
    assert_includes source, '"--paginate"', "gh_json 必须真的加 --paginate"
  end

  # --- success 的语义 ---

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
