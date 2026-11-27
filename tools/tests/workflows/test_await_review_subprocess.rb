# frozen_string_literal: true

# 单次 gh 调用的硬超时，以及超时后真的杀掉子进程（含忽略 TERM 的后代）。
#
# 实测 Ruby 3.4.13：`Timeout` 包住 `capture3` 给 1s 超时仍跑满 6.01s
# （capture3 在 ensure 里 join 子进程），所以实现用的是 popen2e + 进程组。
# 只断言耗时不够——`sh -c "sleep 10"` 可能被 shell 直接 exec 掉、没有后代可杀，
# 测试就会永远绿；因此这里用 sh 起一个忽略 TERM 的后代并核对它真的消失。
#
# 本文件会真起进程，故与其余 await_review 用例分开，避免被 -n 过滤时误跑。

require_relative "../support/boot"
require_relative "../../await_review"

class AwaitReviewSubprocessTest < Minitest::Test
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

end
