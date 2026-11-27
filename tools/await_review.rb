# frozen_string_literal: true

# 「先 review 再跑 CI」的前置门闸。
#
# ## 为什么需要它
#
# 原先 CodeRabbit 与三平台矩阵并行起跑：矩阵常 1-2 分钟就绿，review 还没出结论，
# Implementer 于是先按绿灯推进（甚至 auto-merge），收到意见后再推 commit，
# 一整轮矩阵白烧。把 review 摆到前面，能让「要改的地方」在烧掉三个平台之前暴露。
#
# ## 为什么是 fail-open（与仓库其他工具的 fail-closed 相反）
#
# 仓库对 tools/** 的 fail-closed 纪律针对的是**授权与身份校验**：元数据缺失、
# 身份不可信时必须拒绝。那条纪律的权威表述已同步限定范围（见
# docs/design/process/implementer-loop.md 与 .coderabbit.yaml 的 tools/** 审阅指令），
# 本脚本是其中显式声明的例外。
#
# 本脚本不是校验器，是**顺序门闸**——它只回答「审查这轮跑完了没有」，
# 不判定任何质量结论。门闸卡住 PR 的代价（draft 永远等不到、审查方被卸载
# 或按 path_filters 全跳过、接口抖动）远大于「这一轮矩阵白跑」。
# 因此下列情形一律放行并打 warning：
#
#   - PR 是 draft（.coderabbit.yaml 的 reviews.auto_review.drafts=false，本就不审）
#   - 宽限期内 check run 始终没出现（不在审查范围：path_filters 全排除、App 未启用）
#   - 出现后超时仍未完成
#   - 审查给出非 success 结论（failure / cancelled / timed_out / skipped …）
#   - 连续多次读不到 check-runs
#   - 缺 REPO / PR_NUMBER / HEAD_SHA（拿不到待审对象，无从等起）
#
# 真正的必检仍是 spec / ameba / verify。本门闸存在的意义是「省」，不是「拦」——
# 因此它在任何情况下都不让下游被 skipped：GitHub 文档明确写着，依赖失败 job 的
# job 会被 skipped 且**可能不阻塞合并**（Troubleshooting required status checks）。
# 若门闸真的红了，必检矩阵跟着 skip，PR 反而绕过了 spec/ameba；所以 ci.yml 里
# 门闸步骤带 continue-on-error，让 job 恒为 success，退化成「照常跑矩阵」。
#
# ## 为什么看 check run 而不看 reviews
#
# review 每轮都会新增一条 COMMENTED 记录，无法区分「本轮结束」与「还会再提」；
# check run 的 status=completed 才代表这一轮审完。
# 按 app.slug 过滤，避免 PR 侧用同名检查冒充审查结果。

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
  # 单次 gh api 的硬超时。gh 无默认请求超时，挂住的 fetch 会一路拖到 job 超时，
  # 而 job 被杀 = 下游必检 skipped = 可能不阻塞合并。
  GH_CALL_TIMEOUT_SECONDS = 60

  class << self
    # 测试注入点：生产为 nil，走真实 gh 与真实时钟。
    attr_accessor :gh_reader, :sleeper, :clock
  end

  module_function

  def run(env: ENV, out: $stdout)
    repo = presence(env["REPO"] || env["GITHUB_REPOSITORY"])
    pr_number = presence(env["PR_NUMBER"])
    sha = presence(env["HEAD_SHA"])
    app_slug = presence(env["REVIEW_APP_SLUG"]) || DEFAULT_APP_SLUG
    check_name = presence(env["REVIEW_CHECK_NAME"]) || DEFAULT_CHECK_NAME
    timeout = integer(env["REVIEW_TIMEOUT_SECONDS"], DEFAULT_TIMEOUT_SECONDS)
    interval = integer(env["REVIEW_POLL_SECONDS"], DEFAULT_POLL_SECONDS)

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

    await(
      repo: repo, sha: sha, app_slug: app_slug, check_name: check_name,
      timeout: timeout, interval: interval, out: out,
      appear_timeout: integer(env["REVIEW_APPEAR_SECONDS"], DEFAULT_APPEAR_SECONDS)
    )
  end

  # 实测 normal 情况：本 PR 门闸等 9m45s（CodeRabbit 9m30s）。20 分钟 job 上限
  # 只比 15 分钟脚本等待多 5 分钟，若 gh 调用本身挂起，job 会被 GitHub 杀掉。
  # 步骤级超时保证「脚本挂住」也走不到「下游被 skip」那条路。
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

  # 审查流程跑完（success）才算正常路径；其余结论都按「没审成」放行。
  # 注意 success 只代表流程完成，不代表没有可修意见——意见在 review 评论里，
  # 门闸只保证顺序，不承担质量判定。
  def judge(run, out)
    conclusion = run["conclusion"].to_s
    if conclusion == "success"
      out.puts "审查已完成：#{run["name"]} conclusion=success"
      return 0
    end

    pass_open(out, "审查未给出成功结论（conclusion=#{conclusion.empty? ? "null" : conclusion}）")
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

  def gh_json(path)
    return gh_reader.call(path) if gh_reader

    # gh 自身没有默认请求超时：一次挂住的 fetch 会让整个 job 卡到 GitHub 的
    # job 超时，而 job 被杀后下游 spec / ameba 是 skipped——那正是本门闸
    # 最该避免的形态（见头注释）。用 Ruby 侧 Timeout 兜住单次调用。
    out, err, status = Timeout.timeout(GH_CALL_TIMEOUT_SECONDS) do
      Open3.capture3("gh", "api", path)
    end
    raise "gh api #{path} 失败：#{err.strip}" unless status.success?

    JSON.parse(out)
  rescue Timeout::Error
    raise "gh api #{path} 超时（#{GH_CALL_TIMEOUT_SECONDS}s）"
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
