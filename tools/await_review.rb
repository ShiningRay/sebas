# frozen_string_literal: true

# 「先 review 再跑 CI」的前置门闸。
#
# ## 两条职责
#
#   1. 排序：审查没跑完，三平台矩阵不起跑（省一轮三平台 runner）；
#   2. 拦截：审查提出了需整改项，矩阵不起跑，等改完再 push。
#
# 原先 CodeRabbit 与矩阵并行：矩阵 1-2 分钟就绿，审查还没出结论，实现方按绿灯
# 推进、收到意见再推 commit，一整轮矩阵白烧。职责 1 把这段浪费省掉。
# 职责 2 更进一步：让「要改什么」在烧掉三个平台之前暴露，而不是先跑完再说。
#
# ## 为什么大部分路径是 fail-open
#
# 仓库对 tools/** 的 fail-closed 纪律针对的是**授权与身份校验**：元数据缺失、
# 身份不可信时必须拒绝。那条纪律的权威表述已限定范围（见 .coderabbit.yaml 的
# tools/** 审阅指令），本脚本是其中显式声明的例外。
#
# 判断依据分两层：
#   - 「审查有没有结论」——拿不到就放行（draft 从不审、App 被卸载、path_filters
#     全跳过、接口抖动），把 PR 卡死在这里的代价远大于「这一轮矩阵白跑」；
#   - 「结论说要不要改」——只认审查方自己写的 actionable 条数，读不到 review
#     同样放行（拿不到结论 ≠ 确认有问题）。
#
# 下列情形一律放行并打 warning：
#   - PR 是 draft（.coderabbit.yaml 的 reviews.auto_review.drafts=false，本就不审）
#   - 宽限期内 check run 始终没出现（不在审查范围：path_filters 全排除、App 未启用）
#   - 出现后超时仍未完成
#   - 审查给出非 success 结论（failure / cancelled / timed_out / skipped …）
#   - 连续多次读不到 check-runs
#   - 缺 REPO / PR_NUMBER / HEAD_SHA（拿不到待审对象，无从等起）
#   - 读不到 review 列表（含接口形状异常）
#
# 唯一会返回非 0 的是「审查成功且有 actionable 项」——那时矩阵被 skip 是**目的**，
# 不是副作用。因此 ci.yml 里门闸对 await-review job 是真正的工作判定，
# 与「job 恒为 success」的旧口径相反；改口径的原因见 ci.yml 该 job 的注释。
#
# ## 为什么排序看 check run 而不看 reviews
#
# review 每轮都会新增一条 COMMENTED 记录，无法区分「本轮结束」与「还会再提」；
# check run 的 status=completed 才代表这一轮审完。
# 按 app.slug 过滤，避免 PR 侧用同名检查冒充审查结果。
#
# ## 为什么整改看 actionable 文案而不看 review thread
#
# thread 可以被人手动 resolve 掉而代码未改；`Actionable comments posted: N`
# 是审查方自己的原始判断，不受人工操作影响。代价是耦合了 CodeRabbit 的文案，
# 所以匹配失败时按「无整改项」处理（fail-open）。

require "json"
require "open3"
require "timeout"

module AwaitReview
  DEFAULT_APP_SLUG = "coderabbitai"
  DEFAULT_CHECK_NAME = "CodeRabbit"
  DEFAULT_TIMEOUT_SECONDS = 900
  # 等 check run「出现」的上限。超时即认为该 PR 不在审查范围内。
  DEFAULT_APPEAR_SECONDS = 300
  DEFAULT_POLL_SECONDS = 20
  # 连续读接口失败到上限就放行：审查不是安全边界，不该因网络抖动阻塞合并。
  MAX_CONSECUTIVE_ERRORS = 3
  # 单次 gh api 的硬超时。gh 无默认请求超时，挂住的 fetch 会一路拖到 job 超时。
  GH_CALL_TIMEOUT_SECONDS = 60
  # 超时终止的宽限：先 TERM 给进程体面退出的时间，宽限用完仍在就 KILL。
  # 两者都很短——这是「已经超时」的清理路径，不该再占着步骤时间。
  TERM_GRACE_SECONDS = 2.0
  KILL_GRACE_SECONDS = 1.0
  # CodeRabbit 在 review 正文里写「Actionable comments posted: N」，N>0 表示
  # 该 commit 上有必须整改的条目。
  ACTIONABLE_PATTERN = /Actionable comments posted:\s*(\d+)/
  # 门闸贴在 PR 上的清单评论 marker：重跑时更新同一条，避免刷屏。
  COMMENT_MARKER = "<!-- await-review:blocked -->"

  class << self
    # 测试注入点：生产为 nil，走真实 gh 与真实时钟。
    attr_accessor :gh_reader, :sleeper, :clock, :gh_writer
  end

  module_function

  def run(env: ENV, out: $stdout)
    repo = presence(env["REPO"] || env["GITHUB_REPOSITORY"])
    pr_number = presence(env["PR_NUMBER"])
    sha = presence(env["HEAD_SHA"])

    if repo.nil? || pr_number.nil? || sha.nil?
      return pass_open(out, "缺 REPO / PR_NUMBER / HEAD_SHA，无法定位待审提交")
    end

    begin
      if draft?(repo, pr_number)
        return pass_open(out, "PR ##{pr_number} 是 draft，审查方按配置不审 draft")
      end
    rescue StandardError => e
      return pass_open(out, "读 PR ##{pr_number} 状态失败（#{e.message}）")
    end

    verdict = await(
      repo: repo, sha: sha,
      app_slug: presence(env["REVIEW_APP_SLUG"]) || DEFAULT_APP_SLUG,
      check_name: presence(env["REVIEW_CHECK_NAME"]) || DEFAULT_CHECK_NAME,
      timeout: integer(env["REVIEW_TIMEOUT_SECONDS"], DEFAULT_TIMEOUT_SECONDS),
      interval: integer(env["REVIEW_POLL_SECONDS"], DEFAULT_POLL_SECONDS),
      appear_timeout: integer(env["REVIEW_APPEAR_SECONDS"], DEFAULT_APPEAR_SECONDS),
      out: out
    )
    # 只有「审查确实跑完且成功」才走到整改判定；其余已 fail-open 放行，
    # 此时去读 actionable 既读不到什么，也没资格挡住 PR。
    return 0 unless verdict == :reviewed

    guard_actionable(repo: repo, pr_number: pr_number, sha: sha, out: out,
      comment: env["GATE_COMMENT"] != "false")
  end

  def await(repo:, sha:, app_slug:, check_name:, timeout:, interval:, appear_timeout:, out:)
    start = now
    deadline = start + timeout
    # 「等它出现」与「等它跑完」是两件事：审查方对本 PR 不产生 check run 时
    # （path_filters 全排除、App 未启用、被跳过），死等到主上限只会白占矩阵队列。
    # 实测正常创建延迟 18-23s，偶发 113s，故给 5 分钟宽限。
    # 取 min 是为了让 env 把 appear 配得比 timeout 更大时不会越过主上限。
    appear_deadline = [start + appear_timeout, deadline].min
    # 见过之后再遇到接口错误不能退回「等出现」的口径——审查看起来还在跑，
    # 就算 appear 窗已过也必须按主上限重试（CodeRabbit 在 PR #280 指出：
    # 第 280s 读到 in_progress、第 320s 读失败时，异常分支把 runs 置空，
    # 会按已过期的 appear_deadline 直接放行，矩阵在审查未完时起跑）。
    seen = false
    errors = 0

    loop do
      runs = nil
      begin
        runs = fetch_check_runs(repo, sha)
        errors = 0
      rescue StandardError => e
        errors += 1
        return pass_open(out, "连续 #{errors} 次读取 check-runs 失败（#{e.message}）") if errors >= MAX_CONSECUTIVE_ERRORS

        out.puts "读取 check-runs 失败（第 #{errors}/#{MAX_CONSECUTIVE_ERRORS} 次）：#{e.message}"
        runs = []
      end

      # 每轮只取一次时刻：判断与算剩余量必须基于同一时刻，否则两次调用之间的
      # 时间差会让 remain 提前归零（逻辑时钟测试把它放大成误判超时）。
      current = now

      run = pick(runs, app_slug, check_name)
      # 读失败不等于「没出现」：若之前见过它，这一轮只是暂时读不到，
      # 不能把它当「从未出现过」而按出现窗放行。
      read_failed = runs.empty? && errors.positive?
      if run.nil?
        unless read_failed
          if current >= appear_deadline
            return pass_open(out, "#{appear_timeout}s 内未出现 #{app_slug} 的 #{check_name} check run" \
                                   "（该 PR 大概不在审查范围内）")
          end
          out.puts "尚未出现 #{app_slug} 的 #{check_name} check run（head=#{sha[0, 8]}）"
        end
      else
        seen = true
        return judge(run, out) if run["status"] == "completed"

        out.puts "等待 #{check_name} 完成（status=#{run["status"]}）"
      end

      # 只有「从未出现过」才受出现窗约束；一旦见过，一律按主上限等。
      remaining = (seen || read_failed ? deadline : appear_deadline) - current
      if remaining <= 0
        return pass_open(out, "等待审查超时 #{timeout}s，check run 仍未完成（status=#{run && run["status"]}）")
      end

      sleep_for([interval, remaining].min)
    end
  end

  # 审查流程跑完（success）返回 :reviewed，交给调用方继续判整改；
  # 其余结论都按「没审成」放行并返回 0。
  def judge(run, out)
    conclusion = run["conclusion"].to_s
    if conclusion == "success"
      out.puts "审查已完成：#{run["name"]} conclusion=success"
      return :reviewed
    end

    pass_open(out, "审查未给出成功结论（conclusion=#{conclusion.empty? ? "null" : conclusion}）")
  end

  # 判定「这次审查有没有必须整改的条目」，有则挡住矩阵（返回 1）。
  #
  # 只看当前 head 上的 review：旧 commit 的意见不该挡住已经修过的新 commit。
  def guard_actionable(repo:, pr_number:, sha:, out:, comment:)
    reviews = fetch_reviews(repo, pr_number, sha)
    return pass_open(out, "读不到 #{sha[0, 8]} 上的 review，无法判断是否需整改") if reviews.nil?

    actionable = reviews.sum { |review| actionable_count(review) }
    if actionable.zero?
      out.puts "审查未提出需整改项（#{sha[0, 8]}），放行"
      return 0
    end

    out.puts "::error::审查提出 #{actionable} 条需整改项（#{sha[0, 8]}），矩阵不跑"
    post_block_comment(repo, pr_number, sha, actionable, out) if comment
    1
  end

  # nil 表示读取失败（区别于「读到空列表」）。
  # 结构校验必须显式：Array(hash) 会把 Hash 拆成键值对数组，后续在字符串上取
  # review["commit_id"] 抛 no implicit conversion，被 rescue 吞成「读取失败」——
  # 看着像网络问题，实际是接口形状变了。
  def fetch_reviews(repo, pr_number, sha)
    data = gh_json("repos/#{repo}/pulls/#{pr_number}/reviews?per_page=100")
    raise "reviews 不是数组：#{data.class}" unless data.is_a?(Array)

    data.select { |review| review.is_a?(Hash) && review["commit_id"].to_s == sha }
  rescue StandardError => e
    warn "读取 review 失败：#{e.message}"
    nil
  end

  # review 正文没有该文案 = 这条 review 没有 actionable 项。
  def actionable_count(review)
    match = ACTIONABLE_PATTERN.match(review["body"].to_s)
    match ? match[1].to_i : 0
  end

  # 贴一条清单评论：让人不必翻 review 就知道卡在哪。
  # 失败不影响门闸结论——评论只是便利，判定已由退出码表达。
  def post_block_comment(repo, pr_number, sha, actionable, out)
    body = comment_body(sha, actionable)
    existing = find_comment(repo, pr_number)
    if existing
      gh_api_write("PATCH", "repos/#{repo}/issues/comments/#{existing}", {"body" => body})
    else
      gh_api_write("POST", "repos/#{repo}/issues/#{pr_number}/comments", {"body" => body})
    end
    out.puts "已#{existing ? "更新" : "发布"}整改清单评论"
  rescue StandardError => e
    out.puts "::warning::发布整改清单评论失败（不影响判定）：#{e.message}"
  end

  def comment_body(sha, actionable)
    <<~BODY
      #{COMMENT_MARKER}
      ## 先整改 review 意见，矩阵暂不起跑

      CodeRabbit 在 `#{sha[0, 8]}` 上提出 **#{actionable} 条需整改项**，
      三平台矩阵与 ameba 已跳过（省一轮 runner）。

      处理方式：修完再 push，新一轮门闸重判；整改项清零即放行。
      具体条目见本 PR 的 CodeRabbit review。

      <sub>门闸：`tools/await_review.rb`；规则见 `docs/design/process/development-workflow.md` §4</sub>
    BODY
  end

  # 找回上一次贴的评论，避免每轮 push 都堆一条。
  #
  # 必须翻页：`per_page=100` 只取第一页，PR 评论过百（CodeRabbit 每轮都写、
  # verify 也写）时旧评论会落到第二页，于是每次重跑都误判「没贴过」并再发一条。
  # gh api 的 --paginate 会把多页数组拼成一个 JSON 数组返回。
  def find_comment(repo, pr_number)
    data = gh_json("repos/#{repo}/issues/#{pr_number}/comments?per_page=100", paginate: true)
    return nil unless data.is_a?(Array)

    data.reverse.find { |c| c.is_a?(Hash) && c["body"].to_s.start_with?(COMMENT_MARKER) }&.fetch("id", nil)
  rescue StandardError
    nil
  end

  def gh_api_write(method, path, payload)
    return gh_writer.call(method, path, payload) if gh_writer

    out, status = run_command("gh", "api", "-X", method, path, "--input", "-",
      stdin: JSON.generate(payload))
    return if status&.success?

    raise "gh api #{method} #{path} 失败：#{out.strip}"
  end

  def draft?(repo, pr_number)
    gh_json("repos/#{repo}/pulls/#{pr_number}")["draft"] == true
  end

  def fetch_check_runs(repo, sha)
    data = gh_json("repos/#{repo}/commits/#{sha}/check-runs?per_page=100&filter=latest")
    Array(data["check_runs"])
  end

  # 同一 sha 上重跑会产出多条同名 check run，取开始时间最新的一条。
  # app 单独判：check run 的 app 可能为 null，直接 dig 会在 nil 上调用 dig 抛
  # TypeError，把「没有审查结果」误报成工具故障。
  def pick(runs, app_slug, check_name)
    candidates = runs.select do |run|
      run["name"] == check_name && app_of(run) == app_slug
    end
    candidates.max_by { |run| run["started_at"].to_s }
  end

  def app_of(run)
    app = run["app"]
    app.is_a?(Hash) ? app["slug"] : nil
  end

  def pass_open(out, reason)
    out.puts "::warning::门闸放行（fail-open）：#{reason}"
    0
  end

  # gh 调用走 run_command（带硬超时与进程组终止），这里只做错误归一。
  # paginate: true 用于列表接口：`per_page=100` 只取第一页，评论/check run 多时
  # 会漏掉后面的，`--paginate` 让 gh 自行翻页并拼成一个数组。
  def gh_json(path, paginate: false)
    return gh_reader.call(path) if gh_reader

    command = ["gh", "api"]
    command << "--paginate" if paginate
    command << path
    out, status = run_command(*command)
    return JSON.parse(out) if status&.success?

    # gh 在失败时把原因写 stderr，popen2e 合并到同一流里；两者都在 out 中。
    # gh 失败时 JSON 与 `gh: ...` 之间可能没有换行，先摘 `gh:` 段更可读。
    detail = out[/gh: .*\z/m]&.strip || out.strip
    raise "gh api #{path} 失败：#{detail}"
  end

  # 跑外部命令并施加硬超时，返回 [输出, 进程状态]。
  #
  # stdin 用于 `gh api --input -`（贴评论要传 JSON 体）。写完必须关闭，
  # 否则 gh 会一直等 EOF；写管道也可能因 gh 提前退出抛 EPIPE，
  # 那是「命令已结束」而非致命错误，吞掉后照常读输出与状态。
  #
  # 不能用「Timeout 包住 capture3」那种写法：实测 Ruby 3.4.13 下 capture3 会在
  # ensure 里 join 子进程，外层 Timeout 抛异常后仍会等到子进程退出——给
  # `sleep 6` 套 1s 超时，实际耗时 6.01s，超时形同虚设（CodeRabbit 在 PR #280 指出）。
  #
  # 改用 popen2e + 独立进程组，超时后 kill 整组再回收，实测 1.31s 生效。
  def run_command(*command, stdin: nil)
    out = +""
    status = nil
    Open3.popen2e(*command, pgroup: true) do |input, stdout, wait_thr|
      begin
        input.write(stdin) if stdin
      rescue Errno::EPIPE
        nil
      ensure
        begin
          input.close
        rescue IOError
          nil
        end
      end

      begin
        Timeout.timeout(GH_CALL_TIMEOUT_SECONDS) do
          out = stdout.read
          status = wait_thr.value
        end
      rescue Timeout::Error
        terminate(wait_thr.pid)
        raise "#{command.join(" ")} 超时（#{GH_CALL_TIMEOUT_SECONDS}s），已终止"
      end
    end
    [out, status]
  end

  # 终止一个「超时命令」的整个进程组。
  #
  # 为什么不能只 kill 直接子进程：gh 会再拉起子进程（凭据助手、分页跟随），
  # 只杀组长会留下孤儿继续占着管道；而 Open3.popen2e 的块退出会 join 组长，
  # 组长若忽略 TERM 就一路等到它自己退出，60s 硬超时形同虚设
  # （CodeRabbit 在 PR #280 两轮指出这一点）。
  #
  # 步骤：TERM 整组 → 宽限期内轮询组长是否退出 → 仍在就 KILL 整组 →
  # 回收组长 → 确认整组消失（`kill(0, -pid)` 探测）。任一步发现组已空即快速返回。
  def terminate(pid)
    signal_group("TERM", pid)
    reaped = wait_reap(pid, TERM_GRACE_SECONDS)
    # 只有「组长已回收 且 组里也没有后代」才算彻底结束；
    # 任一未满足都必须升级 KILL，否则忽略 TERM 的进程会把超时拖失效。
    unless reaped && group_alive?(pid) == false
      signal_group("KILL", pid)
      reaped = wait_reap(pid, KILL_GRACE_SECONDS) || reaped
    end
    ensure_group_gone(pid)
    reaped || reap_blocking(pid)
  end

  def signal_group(signal, pid)
    Process.kill(signal, -pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    # 组已经空了（ESRCH）或没有权限（EPERM，理论上不会发生在自己的子进程上）。
    false
  end

  # 在宽限期内轮询组长，返回是否已回收。
  def wait_reap(pid, grace_seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace_seconds
    loop do
      return true if reap_nonblocking(pid)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep(0.05)
    end
  end

  def reap_nonblocking(pid)
    Process.waitpid(pid, Process::WNOHANG).nil? ? false : true
  rescue Errno::ECHILD
    true # 已被回收（或本就是别人的子进程）
  end

  def reap_blocking(pid)
    Process.waitpid(pid)
    true
  rescue Errno::ECHILD
    true
  end

  # kill(0, -pid) 只做权限/存在性检查，不投递信号。
  # true = 组里还有进程，false = 组已空，nil = 无法判断（当作已空，避免死等）。
  def group_alive?(pid)
    Process.kill(0, -pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    nil
  end

  # 最后确认：仍活着就再 KILL 一次并短暂等待，不无限重试——
  # 僵尸进程需父进程回收，卡在这里反而会拖住 job。
  def ensure_group_gone(pid)
    return unless group_alive?(pid)

    signal_group("KILL", pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + KILL_GRACE_SECONDS
    while group_alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep(0.05)
    end
  end

  def now
    clock ? clock.call : Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def sleep_for(seconds)
    return if seconds <= 0

    sleeper ? sleeper.call(seconds) : sleep(seconds)
  end

  def presence(value)
    text = value.to_s.strip
    text.empty? ? nil : text
  end

  def integer(value, fallback)
    parsed = Integer(value.to_s, 10, exception: false)
    parsed && parsed.positive? ? parsed : fallback
  end
end

exit(AwaitReview.run) if $PROGRAM_NAME == __FILE__
