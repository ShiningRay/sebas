# frozen_string_literal: true

require "json"
require "socket"
require_relative "policy/scope"

module SebasAgents
  # CLI：所有子命令默认 dry-run，只有 --apply 才写远端或本地版本文件。
  class CLI
    EXIT_OK = 0
    EXIT_REFUSED = 1
    EXIT_USAGE = 2
    # 拿不到跨机 ref 锁（#306；续篇 §4 口径「第二实例退出码 2」）。
    # 与 EXIT_USAGE 同值：本次调用都未执行写动作；输出 JSON 里以
    # status=refused + lock_holder 与用法错误区分。
    EXIT_LOCKED = 2

    def initialize(out: $stdout, err: $stderr)
      @out = out
      @err = err
    end

    def run(argv)
      dispatch(argv)
    rescue UsageError => e
      Output.error(e.message, code: "usage_error", out: @out)
      EXIT_USAGE
    rescue InvalidPlan => e
      Output.error(e.message, code: "invalid_plan", out: @out)
      EXIT_REFUSED
    rescue CommandError => e
      Output.error(e.message, code: "command_failed", out: @out)
      EXIT_USAGE
    rescue Error => e
      Output.error(e.message, code: "error", out: @out)
      EXIT_USAGE
    rescue SystemExit
      raise
    # 兜底：任何未预期的 Ruby 异常都转成可解析 JSON，且给「环境错误」退出码。
    rescue StandardError => e
      Output.error("#{e.class}: #{e.message}", code: "internal_error", out: @out)
      EXIT_USAGE
    end

    private

    def dispatch(argv)
      command = argv.first
      case command
      when "next" then run_next(argv.drop(1))
      when "plan" then run_plan(argv.drop(1))
      when "claim" then run_claim(argv.drop(1))
      when "resume" then run_resume(argv.drop(1))
      when "unclaim" then run_unclaim(argv.drop(1))
      when "release" then run_release(argv.drop(1))
      when "verify" then run_verify(argv.drop(1))
      when "triage" then run_triage(argv.drop(1))
      when "digest" then run_digest(argv.drop(1))
      when "queue" then run_queue(argv.drop(1))
      when "heartbeat" then run_heartbeat(argv.drop(1))
      when "mark-review" then run_mark_review(argv.drop(1))
      when "docs-check" then run_docs_check(argv.drop(1))
      when "release" then run_release(argv.drop(1))
      when "roles", "role" then run_roles(argv.drop(1))
      when "version", "--version", "-v" then version
      when nil, "--help", "-h", "help" then help
      else
        raise UsageError, "未知子命令 #{command.inspect}；运行 ruby tools/sebas-process help"
      end
    end

    def version
      Output.emit(version_payload, out: @out)
      EXIT_OK
    end

    def root(options)
      File.expand_path(options[:root] || Dir.pwd)
    end

    def runner(options)
      CommandRunner.new(dry_run: !options[:apply])
    end

    def snapshot(options, proposal_issue: nil, verified_pr: nil)
      snap = load_snapshot(options[:snapshot]) if options[:snapshot]
      unless snap
        repo = options[:repo] || default_repo
        gateway = GithubGateway.new(runner(options), repo: repo)
        snap = gateway.snapshot(proposal_issue: proposal_issue, verified_pr: verified_pr)
      end
      # 迁移期容量钳制（Q10=B：迁移期容量恒 1）：v1 记录仍有活动（非 released）
      # 时有效容量回落 1，与单卡行为一致；released 遗留记录不构成约束。
      # 只影响路由与认领判定，不改快照事实源本身。
      snap = snap.with(capacity: 1) if migration_capacity_clamp?
      snap
    end

    # 迁移窗口内是否仍钳制容量：legacy run.json 存在且其记录非 released。
    # 文件缺失不钳制；损坏/非法记录不吞异常——读取失败直接抛错拒绝命令
    # （fail-closed），不得把「读不出来」当成「不钳制」放行容量提升。
    def migration_capacity_clamp?
      path = RunRecord::DEFAULT_PATH
      return false unless File.exist?(path)

      data = RunRecord.new(path: path).load
      data && data["phase"].to_s != "released"
    end

    # 快照是唯一事实源：结构不全就拒绝，绝不把缺失当成「没有工作」。
    def load_snapshot(path)
      data = JSON.parse(File.read(path, encoding: "UTF-8"))
      raise InvalidPlan, "快照必须是 JSON 对象：#{path}" unless data.is_a?(Hash)

      missing = %w[milestones issues].reject { |key| data[key].is_a?(Array) }
      unless missing.empty?
        raise InvalidPlan, "快照缺少 #{missing.join("、")} 数组，无法判定：#{path}"
      end
      if data["main_sha"].to_s.empty?
        raise InvalidPlan, "快照缺 main_sha，无法确认观测基准：#{path}"
      end

      Model::Snapshot.from_hash(data)
    rescue JSON::ParserError => e
      raise UsageError, "快照不是合法 JSON：#{path}（#{e.message}）"
    rescue Errno::ENOENT
      raise UsageError, "快照文件不存在：#{path}"
    end

    def default_repo
      ENV["SEBAS_REPO"] || repo_from_remote
    end

    def repo_from_remote
      result = CommandRunner.new(dry_run: false).capture("git", "remote", "get-url", "origin")
      raise UsageError, "无法推断仓库；请用 --repo OWNER/NAME" unless result.success?

      url = result.stdout.strip
      match = url.match(%r{[:/]([^/:]+/[^/:]+?)(?:\.git)?\z})
      raise UsageError, "无法从 origin 推断仓库：#{url}" unless match

      match[1]
    end

    # 全部活动记录（§4.1 逐租约路由的输入）。
    # 迁移窗口（legacy run.json 仍在）内保持容量 1：出现多份活动记录即
    # invalid_plan（Q10=B 迁移期语义不变）。
    def active_records_for(options)
      # 显式 --record 不是「没有记录」：路由据此判 owned，返回空数组会把
      # 本机持有的租约当成异机租约（容量满时误报 wait）。
      if options[:record]
        data = RunRecord.new(path: options[:record]).load
        return data && !data.empty? ? [data] : []
      end

      active = RunRecord.active_records
      migration_window = File.exist?(RunRecord::DEFAULT_PATH)
      if active.length > 1 && migration_window
        raise InvalidPlan, "迁移窗口内存在 #{active.length} 份活动运行记录（迁移期容量 1），需人工确认迁移"
      end
      legacy = RunRecord.new(path: RunRecord::DEFAULT_PATH).load
      active + (legacy && !legacy.empty? ? [legacy] : [])
    end

    # 单条记录入口（兼容 --record 与「只看一张」的调用方）。
    # 未指定 issue 时返回本机持有的第一条活动记录：多租约下真正的逐卡求值
    # 由 routing 的 records 参数承担，这里只保证旧的单记录语义不退化。
    def record_for(options, issue: nil)
      explicit = RunRecord.new(path: options[:record]) if options[:record]
      return explicit.load if explicit

      active = active_records_for(options)
      if issue
        return active.find { |data| data["issue"].to_i == issue }
      end

      active.first
    end

    def run_next(argv)
      options, = Argv.parse(argv)
      records = active_records_for(options)
      action = Policy::Selection.select_action(snapshot(options), record: records.first, records: records)
      Output.emit({"ok" => action.action != "invalid_plan"}.merge(action.to_h), out: @out)
      action.action == "invalid_plan" ? EXIT_REFUSED : EXIT_OK
    end


# plan（M4x-Parallel-WP1，#218）：只读多候选视图——与 next 同快照同策略，
# 返回全部就绪候选（容量取快照 capacity，缺省 1；迁移窗口钳回 1）、带枚举
# 码的排除集与验证背压（待验收 PR 数）。不改任何写行为；exit 0 正常 / 1
# invalid_plan。
  def run_plan(argv)
    options, = Argv.parse(argv)
    snap = snapshot(options)
    records = active_records_for(options)
    view = Policy::Selection.plan(snap, record: records.first, records: records)
    changelog = read_changelog(options)
    queue = build_merge_queue(snap, options, view, records, changelog)
    head_entry = queue.entries.first
    candidates = view.ready.map.with_index do |issue, index|
    {
      "issue" => issue.number,
      "title" => issue.title,
      "order" => issue.automation["order"],
      # scope_conflict：该候选与在途租约的 scope 冲突说明。就绪候选恒为 nil
      # （冲突的已进 excluded），保留字段是为了契约稳定与人工核对。
      "scope_conflict" => nil,
      "scope" => issue.automation["scope"],
      "selected" => index.zero?
    }
  end
  payload = {
    "ok" => view.invalid_reason.nil?,
    "capacity" => snap.capacity,
    # 背压可观察（#221 §2）：used/limit 并存，便于直接算剩余槽位。
    "capacity_used" => snap.in_progress_issues.length,
    "capacity_limit" => snap.capacity,
    # 验收背压口径见 MergeQueue.verifier_queue_depth：只数待核验的 merge_ready。
    "verifier_queue_depth" => MergeQueue.verifier_queue_depth(view.leases),
    "next_action" => view.next_action,
    "next_issue" => view.next_issue,
    "candidates" => candidates,
    "excluded" => view.excluded.map do |entry|
      {"issue" => entry["issue"], "reason" => entry["code"], "detail" => entry["reason"]}
    end,
    # 逐租约动作表（§4.1）：每张在途卡的下一步与所属关系，coordinator 据此派活。
    "leases" => view.leases.map(&:to_h),
    # 合并队列状态（M4x-WP4，#222）：队首 PR、队列长度、当前阻塞原因。
    # 与 queue 子命令同一构造点（build_merge_queue），口径同源。
    "merge_queue" => {
      "head" => queue.head,
      "head_pr" => head_entry&.pr,
      "depth" => queue.entries.length,
      "step" => queue.step,
      "blocked_by" => queue.blocked_by
    }.compact,
    "observed_main" => snap.main_sha
  }
  payload["invalid_reason"] = view.invalid_reason if view.invalid_reason
  Output.emit(payload, out: @out)
  view.invalid_reason ? EXIT_REFUSED : EXIT_OK
end

    # 心跳子命令（#221 §5 F5）：worker 存活证明。
    #
    # 为什么不自动在每次命令里写：心跳要证明的正是「worker 还在跑」，只有 worker
    # 自己的循环能给出这件事。coordinator 代写等于把「我读过它的记录」当成
    # 「它还活着」，F5 就永远判不出来。所以这里只提供写入原语，由执行器按自己的
    # 节奏调用（Implementer 长任务期间定期跑）。
    #
    # `--ttl` 给的是判据提示，不写进记录：租约的过期阈值属全局策略，
    # 让每张卡自带阈值会变成「谁喊得久谁不死」。
    def run_heartbeat(argv)
      return help if argv.include?("--help") || argv.include?("-h")

      options, (number,) = Argv.parse(argv, required: ["issue"])
      target = parse_number(number, "issue")
      ttl = options[:ttl] ? parse_number(options[:ttl], "ttl") : nil

      record = options[:record] ? RunRecord.new(path: options[:record]) : RunRecord.new(issue: target)
      data = record.load
      if data.nil? || data.empty?
        return heartbeat_refused(target, "missing",
          "issue ##{target} 没有本地运行记录，无法写心跳（未认领或已释放）")
      end

      # 记录里的 issue 必须与请求一致：心跳写错卡会让另一张卡的失联判定失真。
      if data["issue"].to_i != target
        return heartbeat_refused(target, "mismatch",
          "请求 issue ##{target}，记录里是 ##{data["issue"]}，拒绝写入")
      end

      if data["phase"].to_s == "released"
        return heartbeat_refused(target, "released", "issue ##{target} 的租约已释放，不再写心跳")
      end

      # pid 必须是长期 worker 的 pid。本 CLI 进程写完就退出，用它会让
      # `Worker.state` 把仍在跑的长任务判成 :gone，随后第二个 worker 被派去
      # 做同一张卡——正是 F5 要防的事故。所以 --apply 时强制显式给出。
      worker_pid = options[:pid] ? parse_number(options[:pid], "pid") : nil
      # 非正数必须拒：0 会被 `Worker.pid_of` 归一为 nil（`kill(0, 0)` 探测的是
      # 当前进程组），写进去等于给自己埋一个「心跳新鲜但过期后永远 unknown」的坑。
      if worker_pid && !worker_pid.positive?
        raise UsageError, "--pid 必须是正整数，收到 #{worker_pid}"
      end
      if options[:apply] && worker_pid.nil?
        return heartbeat_refused(target, "pid_required",
          "心跳写的是「worker 还活着」的证据，必须是长期 worker 的 pid；" \
          "本命令的 pid 写完即退出，不能作为判据。请用 --pid <worker pid> 指定" \
          "（或由 worker 在自己的进程内调用 heartbeat!）")
      end

      unless options[:apply]
        payload = {"ok" => true, "dry_run" => true, "issue" => target, "status" => "would_write",
          "phase" => data["phase"], "last_heartbeat_at" => data["last_heartbeat_at"],
          "ttl_seconds" => ttl, "expired" => ttl ? record.heartbeat_expired?(ttl) : nil,
          "pid" => worker_pid}
        Output.emit(payload, out: @out)
        return EXIT_OK
      end

      # 锁内复核 lease_id 与 phase：调用方读到写入之间可能发生「L1 释放 →
      # 同一张卡被认领为 L2」，不复核就会把 L1 的 pid 写进 L2 的记录。
      written = record.heartbeat!(pid: worker_pid,
        expect_lease_id: data["lease_id"], expect_phase: data["phase"])
      if written.nil?
        return heartbeat_refused(target, record.heartbeat_refusal || "refused",
          heartbeat_refusal_reason(record.heartbeat_refusal, target, data))
      end

      Output.emit(
        {"ok" => true, "dry_run" => false, "issue" => target, "status" => "written",
         "phase" => written["phase"], "last_heartbeat_at" => written["last_heartbeat_at"],
         "pid" => written["pid"]},
        out: @out
      )
      EXIT_OK
    end

    def heartbeat_refused(target, status, reason)
      Output.emit({"ok" => false, "issue" => target, "status" => status, "reasons" => [reason]}, out: @out)
      EXIT_REFUSED
    end

    # 拒绝原因要能指导下一步动作：锁被占 → 稍后重试；身份不符 → 这张卡换主了，
    # 别再用旧记录写心跳。
    def heartbeat_refusal_reason(code, target, snapshot_data)
      case code
      when "locked" then "记录锁被另一个活跃进程占用，本次心跳放弃（不影响正确性，稍后重试）"
      when "lease_mismatch"
        "记录里的 lease_id 已从 #{snapshot_data["lease_id"].inspect} 变为其他值" \
          "（这张卡已被重新认领），拒绝用旧身份写心跳"
      when "phase_mismatch"
        "记录 phase 已从 #{snapshot_data["phase"].inspect} 变为其他值，拒绝写入"
      when "released" then "issue ##{target} 的租约已释放，不再写心跳"
      when "missing" then "issue ##{target} 的记录已不存在（可能刚被释放），拒绝写入"
      else "心跳未写入（#{code}）"
      end
    end

    # 合并队列（M4x-Parallel-WP3，#221；Proposal §7.2）。
    # 默认只读规划：算出队首 PR 与它在链上的下一步。
    # `--apply` 才推进队首一步（且只推进「合并」这一步）：
    #   核验归属与目标分支 → verify merge --pre → 绑定 head squash 合并 → 远端复核。
    # 不循环、不追加 CHANGELOG、不等 Evidence：那三件事各需要一次独立决策，
    # 由 coordinator 重跑队列决定（§7.2 的串行单位）。
    # `--auto`（M4x-WP4，#222）：自动触发，见 run_queue_auto。
    # `--changelog <path>` 提供 CHANGELOG.md 正文，缺省读仓库根。
    def run_queue(argv)
      return help if argv.include?("--help") || argv.include?("-h")

      options, = Argv.parse(argv)
      snap = snapshot(options)
      records = active_records_for(options)
      view = Policy::Selection.plan(snap, record: records.first, records: records)
      changelog = read_changelog(options)
      queue = build_merge_queue(snap, options, view, records, changelog)

      payload = {
        "ok" => true,
        "dry_run" => !options[:apply],
        "auto" => !options[:auto].nil?,
        "capacity" => snap.capacity,
        "capacity_used" => snap.in_progress_issues.length,
        "capacity_limit" => snap.capacity,
        # 验收背压口径见 MergeQueue.verifier_queue_depth：只数待核验的 merge_ready。
        "verifier_queue_depth" => MergeQueue.verifier_queue_depth(view.leases),
        "observed_main" => snap.main_sha,
        "changelog_loaded" => !changelog.nil?,
        "queue" => queue.to_h
      }

      return run_queue_auto(snap, options, payload, queue, records, changelog, view) if options[:auto]

      unless options[:apply]
        Output.emit(payload, out: @out)
        return EXIT_OK
      end

      if queue.empty?
        payload["status"] = "empty"
        Output.emit(payload, out: @out)
        return EXIT_OK
      end

      # 合并链全局锁（#306 / §7.2 合并串行）：run_queue 每轮只推进一步并立即
      # 返回（CI 等待发生在两轮调用之间），锁只包住本轮一步的执行段。
      merge_gateway = GithubGateway.new(runner(options), repo: claim_write_repo(snap, options))
      merge_lock = acquire_ref_lock!(merge_gateway, ref: RefLock.merge_ref, purpose: "merge", payload: payload)
      return EXIT_LOCKED if merge_lock.held?
      payload["lock_takeover"] = merge_lock.previous if merge_lock.previous

      code = nil
      begin
        code = queue_apply_step!(snap, options, payload, queue, merge_gateway)
        # 人工通道成功一步即重置该卡的自动失败计数（AutoMerge 的回退预算
        # 只针对自动重试；人工修完并走通一次，说明卡面状态已恢复）。
        # 清零失败（记录锁被占）不得静默：payload 上报，退出码不动——业务
        # 步已成功，但自动路径下一轮可能继续拒判（#312 三轮 review）。
        if code == EXIT_OK && !queue.entries.empty?
          reset = with_record_retry { record_auto_success(options, queue.entries.first.issue) }
          payload["auto_budget_note"] =
            "auto_merge_failures 清零未完成（#{reset}）：自动路径下一轮可能继续拒判，人工成功后再走一步" if reset != :ok
        end
      rescue CommandError => e
        payload["ok"] = false
        payload["reasons"] = ["合并队列写段异常：#{e.message}"]
        code = EXIT_REFUSED
      ensure
        finalize_lock_release!(merge_gateway, RefLock.merge_ref, merge_lock, payload)
      end
      code = EXIT_REFUSED if payload["lock_release_failed"]
      Output.emit(payload, out: @out)
      code
    end

    # 队列规划的唯一构造点：run_queue / run_queue_auto / run_plan 三处共用，
    # 保证「plan 里看到的队列」与「queue 实际执行的队列」同源（口径分叉会让
    # 观察与执行互相矛盾）。
    def build_merge_queue(snap, options, view, records, changelog)
      MergeQueue.plan(view.leases, snap, changelog: changelog,
        pending_evidence: pending_evidence_issues(snap, records),
        verified_heads: verified_heads(records))
    end

    # 合并队列自动触发（M4x-WP4，#222；Proposal §8 阶段 4）。
    #
    # 把阶段 3 的「每步都要人按一次」换成条件齐备即自动推进；门禁不放宽、
    # 权限不新增——每一步仍走 queue_apply_step! 的同一执行段与合并链 ref 锁。
    #
    # auto_merge_enabled 缺省 false：关着时自动路径整体拒绝（dry-run 如实报告
    # disabled，--apply 拒绝执行），行为与阶段 3 完全一致。
    #
    # 同一轮内只接续 verify_pre → 下一步：它不改 head、不清核验记录，且下一步
    # 在锁内全量复核。update_branch / changelog 会作废已核验 head（重核验是
    # 异步的，发生在两轮调用之间），merge 之后是等 Evidence 升级的串行单位——
    # 三者都停轮，等待发生在两次调用之间。
    #
    # 失败回退（fail-closed）：本卡自动失败计入运行记录，达
    # AutoMerge::MAX_FAILURES（初次 + 一次重试）后自动路径拒绝，人工
    # `queue --apply` 成功一步即重置。
    def run_queue_auto(snap, options, payload, queue, records, changelog, view)
      merge_gateway = GithubGateway.new(runner(options), repo: claim_write_repo(snap, options))

      unless merge_gateway.auto_merge_enabled?
        payload["status"] = "disabled"
        payload["reasons"] = [".github/agents.yml 的 auto_merge_enabled 未开启：自动路径拒绝，" \
          "行为与阶段 3 的人工触发完全一致（维护者显式置 true 才启用）"]
        payload["ok"] = false if options[:apply]
        Output.emit(payload, out: @out)
        return options[:apply] ? EXIT_REFUSED : EXIT_OK
      end

      code = EXIT_OK
      steps = []
      emitted = false
      loop do
        entry = queue.entries.first
        if entry.nil?
          if queue.head.nil?
            payload["status"] = "empty"
          else
            # 队首在链上被异步条件挡住（Evidence 背压等）：这是正常等待，
            # 不是失败——按 wait 报告，等待发生在两次调用之间。
            payload["status"] = "wait"
            payload["reasons"] = [queue.blocked_by].compact
          end
          break
        end

        if steps.length >= AutoMerge::MAX_AUTO_STEPS
          # 护栏（#312 review）：接续链有界。正常路径 verify_pre→merge 至多
          # 两步就停；到不了这里。真到了说明链上出现了无进展的推进，停下
          # 交下一轮调用，不让单次调用无限打转。
          payload["status"] = "wait"
          payload["reasons"] = ["单次调用已连续推进 #{steps.length} 步，达到上限，停轮等下一轮"]
          break
        end

        step = entry.step

        unless options[:apply]
          # dry-run 只读预览：预算用锁外读到的近值（信息用途，不执行）。
          failures = auto_failures(records, entry.issue)
          summary = nil
          if step == "merge" && failures < AutoMerge::MAX_FAILURES
            summary = merge_gateway.verifier_summary(entry.pr, entry.head_sha)
          end
          allowed, reason = AutoMerge.gate(step: step, summary: summary, failures: failures)
          if allowed
            payload["status"] = "would_execute"
            payload["step"] = step
            payload["reasons"] = ["自动模式将执行队列步 #{step}" +
              (AutoMerge.continue_after?(step) ? "，成功后同一轮接续下一步" : "，成功后停轮")]
          else
            payload["status"] = "blocked"
            payload["step"] = step
            payload["auto_gate"] = reason
          end
          break
        end

        # --apply：预算重读、终验门、执行、失败计数必须在**同一把合并链锁内**
        # 完成（#312 三轮 review）：锁外准入会让两个重叠调用都拿旧计数过门，
        # 多执行一次失败尝试；失败计数若在锁外补记，后续调用同锁内看不到。
        # 锁冲突时 acquire_ref_lock! 已经输出拒绝 JSON（含 lock_holder）——
        # 本方法不得再 emit 第二份（双 JSON 会让按单文档解析的调用方炸）。
        merge_lock = acquire_ref_lock!(merge_gateway, ref: RefLock.merge_ref, purpose: "merge", payload: payload)
        if merge_lock.held?
          code = EXIT_LOCKED
          emitted = true
          break
        end
        payload["lock_takeover"] = merge_lock.previous if merge_lock.previous

        executed = false
        begin
          begin
            failures = fresh_auto_failures(options, entry.issue)
            summary = nil
            if step == "merge" && failures < AutoMerge::MAX_FAILURES
              # 摘要与 head 绑定（#312 二轮 review）：旧 head 的残留摘要对新
              # head 不成立，传当前 head 供 gateway 过滤。
              summary = merge_gateway.verifier_summary(entry.pr, entry.head_sha)
            end
            allowed, reason = AutoMerge.gate(step: step, summary: summary, failures: failures)
            unless allowed
              # 门拒判是「交人工」的停轮，不是执行失败——不计数（只有真
              # 执行过的步才进计数/清零分支）。
              payload["status"] = "blocked"
              payload["step"] = step
              payload["auto_gate"] = reason
              payload["ok"] = false
              code = EXIT_REFUSED
            else
              executed = true
              code = queue_apply_step!(snap, options, payload, queue, merge_gateway)
            end
          rescue CommandError => e
            payload["ok"] = false
            payload["reasons"] = ["合并队列写段异常：#{e.message}"]
            code = EXIT_REFUSED
          end

          # 锁内计数/清零（释放前完成，后续调用同锁可见）。清零失败只上报
          # 不停摆：锁内重读的预算就是真实状态，下一步准入会自洽拒判；但
          # 清零未完成时不得接续下一步（#312 三轮 review）。
          reset_result = :ok
          if executed && code != EXIT_OK && code != EXIT_LOCKED
            result = with_record_retry { record_auto_failure(options, entry.issue, step) }
            payload["auto_budget_note"] =
              "运行记录锁被占（心跳写入中），本次失败未能计入预算（有界重试后仍失败）" if result == :locked
          elsif executed && code == EXIT_OK
            reset_result = with_record_retry { record_auto_success(options, entry.issue) }
            unless reset_result == :ok
              payload["auto_budget_note"] =
                "auto_merge_failures 清零未完成（#{reset_result}）：预算保持旧值，本轮停止接续"
            end
          end
        ensure
          finalize_lock_release!(merge_gateway, RefLock.merge_ref, merge_lock, payload)
        end

        if payload["lock_release_failed"]
          # 业务步可能已成功，但锁没放干净：与人工路径同口径（exit 非 0），
          # 不掩盖未完成的收尾；成功信息留在 payload["status"] 里可审计。
          code = EXIT_REFUSED
          break
        end

        break if code != EXIT_OK

        steps << {"issue" => entry.issue, "step" => step, "result" => payload["status"]}

        break unless AutoMerge.continue_after?(step) && reset_result == :ok

        # verify_pre 成功 → 用新记录重新规划：核验写入后队列应给出下一步。
        # 快照不重取：verify_pre 与其后续步骤之间没有异步事件。
        records = active_records_for(options)
        queue = build_merge_queue(snap, options, view, records, changelog)
      end
      unless emitted
        payload["auto_steps"] = steps unless steps.empty?
        Output.emit(payload, out: @out)
      end
      code
    end

    # 锁内有界重试（#312 三轮 review）：记录锁是心跳级短临界区，短暂等待
    # 重试几乎必得；仍 :locked 就把最后结果交调用方上报——不无限等，也
    # 不把「未能累计/清零」伪装成成功。
    def with_record_retry(limit = 5)
      result = yield
      attempt = 1
      while result == :locked && attempt < limit
        sleep 0.2
        attempt += 1
        result = yield
      end
      result
    end

    # 合并链锁内的预算重读：不走循环顶的 records 快照（可能已被上一轮
    # 调用改写），读当前记录的真实计数。
    def fresh_auto_failures(options, issue)
      record, = owned_record(options, issue)
      return 0 if record.nil?

      data = record.load
      data && data["issue"].to_i == issue.to_i ? data["auto_merge_failures"].to_i : 0
    end

    # 自动失败计数（AutoMerge 回退预算的载体）。只动本卡记录，不碰远端；
    # 读改写必须走 RunRecord 的记录锁（与 heartbeat! 同一把）。
    def record_auto_failure(options, issue, step)
      record, = owned_record(options, issue)
      return :missing if record.nil?

      record.bump_auto_failure!(step)
    end

    # 成功一步即清零（自动成功与人工 `queue --apply` 成功都走这里）。
    def record_auto_success(options, issue)
      record, = owned_record(options, issue)
      return :missing if record.nil?

      record.reset_auto_failure!
    end

    # 本机持有的该卡记录（存在且 issue 匹配）；异机租约没有本地记录，返回空。
    # --record 指定时与 remember_verified_head 同口径读该路径（#312 review），
    # 否则走 per-issue 路径——两条入口不一致会让预算在自定义记录上失灵。
    # 显式路径分支也必须带 issue:（#312 二轮）：bump/reset 的身份检查比对
    # 记录的 issue 与 @issue，缺了它自定义记录恒判 mismatch、预算失灵。
    def owned_record(options, issue)
      record = options[:record] ? RunRecord.new(path: options[:record], issue: issue) : RunRecord.new(issue: issue)
      data = record.load
      data && !data.empty? && data["issue"].to_i == issue.to_i ? [record, data] : [nil, nil]
    end

    def auto_failures(records, issue)
      data = Array(records).find { |r| r["issue"].to_i == issue.to_i }
      data ? data["auto_merge_failures"].to_i : 0
    end

    # 队列单步推进（--apply）：changelog / update_branch / verify_pre / merge 各
    # 一轮一步。单步内的读改写（verify → 记 head → 复核 → 合并 → 回读）是
    # 临界区，由调用方的 merge 锁串行化。只填 payload、返回退出码，输出由
    # 调用方在锁释放后统一进行（review 整改：释放失败不得被业务结果掩盖）。
    def queue_apply_step!(snap, options, payload, queue, merge_gateway)
      entry = queue.entries.first
      pr = snap.pull_request(entry.pr)

      # CHANGELOG 追加是队列自己的一步（§6.3 裁决）：否则带 marker 的 PR 会
      # 永远停在 changelog，重跑队列仍是同一步。追加后再走一次标准合并路径。
      if entry.step == "changelog"
        result = append_changelog!(options, entry, snap)
        payload.update(result)
        return result["ok"] ? EXIT_OK : EXIT_REFUSED
      end

      # BEHIND 是队列自己的第二步（#221 §3）：只推进 update-branch 一次，
      # 不接着合并。理由：update-branch 改 head，旧 head 的核验结论全部作废，
      # 必须由下一轮的 verify merge --pre 与独立核验重新给结论。
      if entry.step == "update_branch"
        result = update_branch!(options, entry, snap)
        payload.update(result)
        return result["ok"] ? EXIT_OK : EXIT_REFUSED
      end

      # `verify_pre` 步骤必须真的跑核验：它是「这个 head 已核验」的唯一写入点。
      # 若这里只报 blocked，队列永远走不到 merge——`next_step` 要求 verified_head
      # 等于当前 head，而没有任何东西会把它写成非空，形成死锁。
      if entry.step == "verify_pre"
        result = run_queue_verify_pre(options, entry, snap)
        payload.update(result)
        return result["ok"] ? EXIT_OK : EXIT_REFUSED
      end

      if entry.step != "merge"
        payload["status"] = "blocked"
        payload["step"] = entry.step
        payload["reasons"] = [queue.blocked_by]
        payload["ok"] = false
        return EXIT_REFUSED
      end

      # 核验前置：不带 --pre 的 verify merge 是合并后口径，合并前必然 blocker。
      pre = Verifier.verify_merge(pr.number, entry.issue, snap, pre: true)
      payload["verify"] = pre.to_h
      unless pre.pass?
        payload["status"] = "refused"
        payload["ok"] = false
        payload["reasons"] = ["verify merge --pre 未通过"] +
                             pre.to_h["items"].to_a.map { |item| item["message"] }
        return EXIT_REFUSED
      end

      # 核验通过即把 head 记进运行记录：队列下一轮靠它判断「当前 head 是否已核验」。
      # 不记的话，update-branch 改完 head 后队列会以为还没核验（正确但永远卡住），
      # 或在没有这层判定时直接合并（错误）。记与判必须成对——写不进记录（他机
      # 租约或记录缺失）就拒绝本步，不能报成功后让队列原地打转（#312 review）。
      unless remember_verified_head(options, entry.issue, pr.head_sha)
        payload["status"] = "refused"
        payload["ok"] = false
        payload["reasons"] = ["verified_head 未能写入本地运行记录（##{entry.issue} 非本机持有租约或记录缺失），" \
                              "队列无法据此推进；本机只续跑自己持有的卡"]
        return EXIT_REFUSED
      end

      # 快照是规划时取的，写之前必须重读：head 与 base 都可能已经变了。
      # （#307 review 整改：merge_gateway 与调用方持锁的是同一 runner，复用
      # 它取新快照，保证合并门禁读到的远端状态在锁内。）
      current = merge_gateway.snapshot.pull_request(pr.number)
      unless current&.open?
        payload["status"] = "refused"
        payload["ok"] = false
        payload["reasons"] = ["合并前复核：PR ##{pr.number} 已不是 open"]
        return EXIT_REFUSED
      end
      # 目标分支必须明确是 main。空值不放行：合并前复核的价值就在于「看到才认」，
      # 读不到 base 时合并等于把目标分支交给默认值。
      unless current.base == "main"
        payload["status"] = "refused"
        payload["ok"] = false
        payload["reasons"] = ["合并前复核：PR ##{pr.number} 的目标分支是 #{current.base.inspect}（只允许 main；缺失即不可判定）"]
        return EXIT_REFUSED
      end
      if current.head_sha != pr.head_sha
        payload["status"] = "refused"
        payload["ok"] = false
        payload["reasons"] = ["合并前复核：head 已从 #{pr.head_sha[0, 8]} 变为 #{current.head_sha[0, 8]}，须重新核验"]
        return EXIT_REFUSED
      end

      # 合并门禁的仓库级复核（#307 review 整改）：Evidence 背压不能只看本机
      # 记录——另一台机器合并的卡在本机 runs/ 里没有记录，锁前快照也看不到
      # 锁后发生的合并。锁内取全仓新快照，扫「已合并但 Evidence 未升级」的
      # 卡，存在即停：main 侧 CI 的 pending 位只有一位，先升级再合下一张。
      backlog = repo_pending_evidence!(merge_gateway.snapshot, skip_issue: entry.issue)
      unless backlog.empty?
        payload["status"] = "blocked"
        payload["ok"] = false
        payload["reasons"] = ["仓库级 Evidence 背压：" +
                              backlog.map { |n| "##{n}" }.join("、") +
                              " 已合并但 Evidence 未升级（merged_into_main != true），按串行单位先等升级完成（含未知/缺失）"]
        return EXIT_REFUSED
      end

      merge_gateway.merge_pr(pr.number, pr.head_sha, allow_write: true)
      merged = merge_gateway.snapshot.pull_request(pr.number)
      unless merged&.merged?
        payload["status"] = "aborted"
        payload["ok"] = false
        payload["reasons"] = ["合并后远端复核未确认 MERGED，需人工核对 PR ##{pr.number}"]
        return EXIT_REFUSED
      end
      # 第三次核对目标分支：gh pr merge 绑不住 base，写前复核与合并之间仍可能被改。
      # 这里只能发现错误，不能撤销已完成的合并——所以要求人工核对，不报 merged。
      # 空值同样不放行：读不到 base 说明这次合并的目标分支不可确认。
      unless merged.base == "main"
        payload["status"] = "aborted"
        payload["ok"] = false
        payload["reasons"] = ["合并后复核：PR ##{pr.number} 的目标分支是 #{merged.base.inspect}（缺失即不可判定），" \
                              "已合并但目标分支不可确认，须人工核对"]
        return EXIT_REFUSED
      end

      payload["status"] = "merged"
      payload["pr"] = pr.number
      payload["issue"] = entry.issue
      payload["head_sha"] = pr.head_sha
      EXIT_OK
    end

    # 仓库级 Evidence 背压（#307 review 整改）：快照（state=all）里所有已合并
    # PR 的关联卡，凡 Evidence 的 merged_into_main != true（含缺失/解析失败，
    # 未知按未完成处理，口径同 pending_evidence_issues）即入列。
    # skip_issue 是本轮正要合并的卡自身——它的 PR 还没合并，不构成背压。
    # proposal 卡排除（#307 二轮 review）：登记脚本明确跳过 proposal，其
    # Evidence 永远不会升级；历史设计 PR 合并后不得永久阻塞队列。
    # 异仓编号（#307 五轮 review）：`Fixes owner/repo#N` 命中的异仓 issue
    # 由 gateway 按 nameWithOwner 拆进 foreign_issues，closing_issues 恒为
    # 本仓编号——本方法只扫 closing_issues，不做减法（同号异仓不得删除
    # 本仓关联，#307 六轮 review）。
    # 缺卡不排除（#307 三轮 review）：state=all 快照缺卡即分页/引用异常，
    # snap_evidence_merged? 对缺卡返回 nil（未知），编号保留继续阻塞——
    # 不静默放行。
    def repo_pending_evidence!(fresh_snap, skip_issue: nil)
      fresh_snap.pull_requests.select(&:merged?)
        .flat_map(&:closing_issues)
        .uniq.reject { |n| n == skip_issue }
        .filter_map do |number|
          issue = fresh_snap.issue(number)
          next if issue&.proposal?

          number unless snap_evidence_merged?(fresh_snap, number) == true
        end
    end

    # 记录某卡当前 head 已通过 verify merge --pre。只动本卡记录，不碰远端。
    # 返回是否真的写入（#312 review）：记录缺失、非本卡记录或记录锁被占时
    # 返回 false，调用方（run_queue_verify_pre / merge 段）据此拒绝本步，
    # 不得报成功。写必须走记录锁（#312 二轮）：锁外整份写回会覆盖并发写入
    # 的 auto_merge_failures 等字段——所有写者共用同一跨进程更新边界。
    def remember_verified_head(options, issue_number, head_sha)
      record = options[:record] ? RunRecord.new(path: options[:record], issue: issue_number) : RunRecord.new(issue: issue_number)
      result = record.set_verified_head!(head_sha)
      result == :ok
    end

    # head 已变（update_branch / CHANGELOG 追加）→ 旧核验结论作废。
    # 同走记录锁（口径同 remember_verified_head）。
    def forget_verified_head(options, issue_number)
      record = options[:record] ? RunRecord.new(path: options[:record], issue: issue_number) : RunRecord.new(issue: issue_number)
      record.set_verified_head!(nil)
      nil
    end

    # 本机记录里各卡的「上一次通过 verify merge --pre 的 head」。
    # 队列用它判断当前 head 是否已核验：update_branch 与 CHANGELOG 追加都会改
    # head，改过之后必须重新核验，不能复用旧结论。
    def verified_heads(records)
      Array(records).each_with_object({}) do |record, out|
        issue = record["issue"].to_i
        head = record["verified_head"].to_s
        out[issue] = head unless issue.zero? || head.empty?
      end
    end

    # 「PR 已合并但 Evidence 还没升级」的 issue 列表（§7.2 的串行单位）。
    # 判据只看本机记录里的卡：记录里仍有 PR、快照显示该 PR 已合并，且快照里
    # 该 issue 的 Evidence 还没有 merged_into_main=true。缺 Evidence 事实时
    # 不猜——不列入，交由 verify merge --pre 在合并前拦。
    def pending_evidence_issues(snap, records)
      Array(records).filter_map do |record|
        next if record["phase"].to_s == "released"
        pr_number = record["pr"].to_i
        next unless pr_number.positive?

        pr = snap.pull_request(pr_number)
        next unless pr&.merged?

        issue = snap.issue(record["issue"].to_i)
        next unless issue

        merged_into_main = snap_evidence_merged?(snap, issue.number)
        # 未知（nil）同样按未完成处理：串行单位宁可多等一轮，也不抢先合下一张。
        issue.number unless merged_into_main == true
      end
    end

    # 从快照读 issue 自己正文里的 Evidence 块（与 Policy::Evidence 同源；
    # gates/externals 只存 gate:/external: 登记，不能混用）。
    # 未登记或解析失败返回 nil（未知），调用方按「未升级」处理。
    def snap_evidence_merged?(snap, issue_number)
      issue = snap.issue(issue_number)
      return nil unless issue

      block = begin
        JsonBlock.one(issue.body, "evidence", subject: "issue ##{issue_number}")
      rescue InvalidPlan
        nil
      end
      return nil unless block.is_a?(Hash)

      block["merged_into_main"]
    end

    # 队列的 `verify_pre` 步骤：跑 `verify merge --pre`，通过才把 head 记进运行
    # 记录。这是 `verified_head` 的唯一非空写入点——`next_step` 要求它与当前
    # head 一致才允许进入 merge，所以这一步必须真的执行，不能只报 blocked。
    #
    # 它只做只读核验 + 写本机记录，不碰远端。
    def run_queue_verify_pre(options, entry, snap)
      pr = snap.pull_request(entry.pr.to_i)
      payload = {"ok" => false, "status" => "refused", "step" => "verify_pre"}
      if pr.nil?
        payload["reasons"] = ["PR ##{entry.pr} 不在快照内，先重新取快照"]
        return payload
      end

      pre = Verifier.verify_merge(pr.number, entry.issue, snap, pre: true)
      payload["verify"] = pre.to_h
      unless pre.pass?
        payload["reasons"] = ["verify merge --pre 未通过"] +
                             pre.to_h["items"].to_a.map { |item| item["message"] }
        return payload
      end

      unless remember_verified_head(options, entry.issue, pr.head_sha)
        # 核验结论写不进本地记录（他机租约或记录缺失）：报成功会让自动链
        # 在同一头上无限重跑 verify_pre，还堵住身后整条队列（#312 review）。
        payload["reasons"] = ["verified_head 未能写入本地运行记录（##{entry.issue} 非本机持有租约或记录缺失），" \
                              "队列无法据此推进；本机只续跑自己持有的卡"]
        return payload
      end
      payload["ok"] = true
      payload["status"] = "verified"
      payload["head_sha"] = pr.head_sha
      payload["reasons"] = ["PR ##{pr.number} 的 head #{pr.head_sha[0, 8]} 已通过 verify merge --pre；" \
                            "重跑 queue 可推进到下一步（独立 Verifier 核验仍是单独一关）"]
      payload
    end

    # BEHIND 的队列步骤（#221 §3）：只做 update-branch，不接着合并。
    #
    # `gh pr update-branch` 改写 head，旧 head 上的 `verify merge --pre` 与独立
    # 核验结论全部作废。所以这里显式要求「更新后重跑核验」，并把新 head 写进
    # 结果，供下一轮快照比对——不复用、不推断。
    def update_branch!(options, entry, snap)
      payload = {"ok" => false, "status" => "refused", "step" => "update_branch"}
      pr_number = entry.pr.to_i
      pr = snap.pull_request(pr_number)
      payload["reasons"] = ["PR ##{pr_number} 不在快照内，先重新取快照"] if pr.nil?
      return payload if pr.nil?

      unless pr.open?
        payload["reasons"] = ["PR ##{pr_number} 已不是 open（#{pr.state}），不能 update-branch"]
        return payload
      end
      unless pr.base == "main"
        payload["reasons"] = ["PR ##{pr_number} 的目标分支是 #{pr.base.inspect}（只允许 main；缺失即不可判定）"]
        return payload
      end

      # 写前重读：快照是规划时取的，BEHIND 状态可能已经变了（他人刚 update 过）。
      gateway = GithubGateway.new(runner(options), repo: claim_write_repo(snap, options))
      current = gateway.snapshot.pull_request(pr_number)
      unless current&.open?
        payload["reasons"] = ["更新前复核：PR ##{pr_number} 已不是 open"]
        return payload
      end
      # 复核 base：规划时是 main，写前可能已被改成 release。`gh pr update-branch`
      # 用的是 PR **当前** base，那样会把 release 合进分支，而不是同步 main。
      unless current.base == "main"
        payload["reasons"] = ["更新前复核：PR ##{pr_number} 的目标分支是 #{current.base.inspect}" \
                              "（只允许 main；缺失即不可判定），拒绝 update-branch"]
        return payload
      end
      unless current.merge_state_status == "BEHIND"
        payload["reasons"] = ["更新前复核：PR ##{pr_number} 状态已是 #{current.merge_state_status.inspect}，不再需要 update-branch"]
        payload["status"] = "skipped"
        payload["ok"] = true
        return payload
      end

      old_head = current.head_sha
      gateway.update_branch(pr_number, allow_write: true)
      after = gateway.snapshot.pull_request(pr_number)
      unless after&.open?
        payload["reasons"] = ["更新后复核：PR ##{pr_number} 已不是 open，须人工核对"]
        return payload
      end
      # base 在写期间也可能被改：确认不了目标是 main 就不能报告「已更新到 main」。
      unless after.base == "main"
        payload["reasons"] = ["更新后复核：PR ##{pr_number} 的目标分支是 #{after.base.inspect}" \
                              "（缺失即不可判定），已执行 update-branch 但目标分支不可确认，须人工核对"]
        return payload
      end
      if after.head_sha == old_head
        # 分支已与 main 同步时 update-branch 可能不改 head。此时不能声称「已更新
        # 并需重新核验」，如实报告让 coordinator 判断。
        payload["reasons"] = ["update-branch 未改变 head（#{old_head[0, 8]}），目标分支可能已不再 BEHIND，重新取快照确认"]
        return payload
      end

      # head 已变：旧核验结论作废，清掉记录让下一轮必须重新核验。
      forget_verified_head(options, entry.issue)
      payload["ok"] = true
      payload["status"] = "updated_branch"
      payload["old_head_sha"] = old_head
      payload["head_sha"] = after.head_sha
      payload["required_next"] = ["verify merge --pre", "独立 Verifier 核验"]
      payload["reasons"] = ["PR ##{pr_number} 已更新到 main（#{old_head[0, 8]} → #{after.head_sha[0, 8]}）；" \
                            "旧核验结论作废，必须重跑 verify merge --pre 与独立核验"]
      payload
    end

    # 把 PR 正文携带的条目追加进 CHANGELOG 并推到租约分支。
    # 幂等：已有本 PR 引用时跳过（重跑队列不会重复追加）。
    def append_changelog!(options, entry, snap)
      entries = entry.changelog_pending
      payload = {"ok" => false, "status" => "aborted", "step" => "changelog"}
      if entries.nil? || entries.empty?
        payload["reasons"] = ["PR ##{entry.pr} 声明了待追加条目但解析为空，需人工补正文"]
        return payload
      end

      path = File.join(root(options), "CHANGELOG.md")
      unless File.exist?(path)
        payload["reasons"] = ["找不到 #{path}"]
        return payload
      end

      content = File.read(path, encoding: "UTF-8")
      if MergeQueue.changelog_recorded?(content, entry.pr)
        payload["ok"] = true
        payload["status"] = "skipped"
        payload["reasons"] = ["CHANGELOG 已有本 PR 条目，跳过追加（幂等）"]
        return payload
      end

      updated = begin
        MergeQueue.append_entries(content, entries, entry.pr)
      rescue InvalidPlan => e
        payload["reasons"] = [e.message]
        return payload
      end

      File.write(path, updated, encoding: "UTF-8")
      record = RunRecord.new(issue: entry.issue)
      current = record.load || {}
      # CHANGELOG 追加会改 head（同 update_branch）：清掉核验记录，下一轮必须重核验。
      # 同时也把 phase 记成 merging，供 F15 对账识别「合并链已开始」。
      record.save(current.merge("phase" => "merging", "changelog_appended" => true,
        "verified_head" => nil)) if current["issue"]

      payload["ok"] = true
      payload["status"] = "changelog_appended"
      payload["appended"] = entries
      payload
    end

    def read_changelog(options)
      path = options[:changelog] || File.join(root(options), "CHANGELOG.md")
      File.read(path, encoding: "UTF-8")
    rescue Errno::ENOENT, Errno::EISDIR
      nil
    end

    def run_claim(argv)
      return help if argv.include?("--help") || argv.include?("-h")

      options, (number,) = Argv.parse(argv, required: ["issue"])
      # 先校验数字，再去访问 GitHub：参数错不该触发网络或仓库探测。
      target = parse_number(number, "issue")
      # 启动搬迁（Q10=B）：v1 记录先走迁移，活动记录 fail-closed 要求人工确认。
      # 仅写路径（--apply）触发；next/plan/claim --dry-run 只读不迁移（CR-0）。
      # 迁移先于快照：迁移窗口容量钳制（migration_capacity_clamp?）据此看到
      # 迁移后的状态，apply 认领不受已搬走的遗留记录误钳。
      RunRecord.migrate_legacy!(options[:record] || RunRecord::DEFAULT_PATH) if options[:apply] && !options[:record]
      snap = snapshot(options)
      issue = snap.issue(target)
      raise UsageError, "issue ##{number} 不在快照内" unless issue

      result = claimability(issue, snap)
      payload = {
        "ok" => result.ready?,
        "dry_run" => !options[:apply],
        "issue" => issue.number,
        "status" => result.status,
        "reasons" => result.reasons
      }
      if options[:apply] && result.ready?
        return claim_write_section!(snap, issue, options, payload)
      end

      Output.emit(payload, out: @out)
      payload["ok"] ? EXIT_OK : EXIT_REFUSED
    end

    # 跨机 ref 锁通用入口（#306）：拿不到即输出 refused JSON，调用方返回
    # EXIT_LOCKED。payload 用 lock=held 标记（不占用各命令自有 status 键的
    # 语义——mark-review 的 status 是目标状态、unclaim 的 status 是生命周期）；
    # lock_holder 带持有者凭据供排障。
    def acquire_ref_lock!(gateway, ref:, purpose:, issue: nil, payload:)
      # dry-run 演练没有写动作，互斥无从谈起（离线快照下 GitHub 侧锁也不可
      # 读）——返回合成凭据直接放行，release! 同口径跳过。
      if gateway.dry_run?
        return RefLock::Outcome.new(status: :acquired, credential: {"lock_id" => nil},
          holder: nil, reasons: [], previous: nil)
      end

      lock = RefLock.acquire!(gateway, ref: ref, purpose: purpose, issue: issue,
        ttl_seconds: gateway.lock_ttl_seconds)
      if lock.held?
        payload["ok"] = false
        payload["lock"] = "held"
        payload["reasons"] = lock.reasons
        payload["lock_holder"] = lock.holder == :unreadable ? "unreadable" : lock.holder
        Output.emit(payload, out: @out)
      end
      lock
    end

    # 释放收尾（review 整改）：release 结果先于最终输出处理——释放失败/
    # 异常必须进入最终可见结果，不得让先前填好的业务成功掩盖它。
    # 声明锁的 TTL 判定与 acquire 同源（gateway.lock_ttl_seconds）。
    def finalize_lock_release!(gateway, ref, lock, payload)
      ok = begin
        RefLock.release!(gateway, ref: ref, lock_id: lock.credential["lock_id"],
          payload: payload, ttl_seconds: gateway.lock_ttl_seconds)
      rescue StandardError => e
        payload["lock_release_error"] = "锁 #{ref} 释放异常：#{e.message}"
        false
      end
      return if ok

      payload["ok"] = false
      payload["lock_release_failed"] = true
      msg = payload.delete("lock_release_mismatch") || payload.delete("lock_release_error")
      (payload["reasons"] ||= []) << msg if msg
    end

    # 认领写段（--apply，#306）：跨机 ref 锁包住「租约预检 → 发凭据 → 写状态 →
    # 回读」整个临界区。GitHub 服务端原子 CAS 保证两台机器同时认领同一张卡时
    # 恰一个拿到锁，另一个读出持有者凭据即退出——拿到锁的进程做租约预检，
    # 天然看不到并发双凭据，F9 只兜底锁外故障。锁是命令级的：返回前释放。
    # 输出在释放收尾之后统一进行（review 整改：释放失败不得被业务结果掩盖）。
    def claim_write_section!(snap, issue, options, payload)
      # 快照决定校验对象；写入必须落在同一仓库，否则会认领一张没校验过的卡。
      repo = claim_write_repo(snap, options)
      # 显式 --record 优先（测试与离线快照用）；缺省走 v2 per-issue 路径。
      record = options[:record] ? RunRecord.new(path: options[:record]) : RunRecord.new(issue: issue.number)
      gateway = GithubGateway.new(runner(options), repo: repo)
      whitelist = gateway.coordinators
      ref = RefLock.lease_ref(issue.number)
      lock = acquire_ref_lock!(gateway, ref: ref, purpose: "lease", issue: issue.number, payload: payload)
      return EXIT_LOCKED if lock.held?
      payload["lock_takeover"] = lock.previous if lock.previous

      code = nil
      begin
        code = claim_write_body!(snap, issue, options, payload, record, gateway, whitelist)
      rescue CommandError => e
        payload["ok"] = false
        (payload["reasons"] ||= []) << "认领写段异常：#{e.message}"
        code = EXIT_REFUSED
      ensure
        finalize_lock_release!(gateway, ref, lock, payload)
      end
      code = EXIT_REFUSED if payload["lock_release_failed"]
      Output.emit(payload, out: @out)
      code
    end

    # 认领写段本体：只填 payload、返回退出码，不做输出（由调用方在锁释放后
    # 统一 emit）。
    def claim_write_body!(snap, issue, options, payload, record, gateway, whitelist)
      # 租约唯一性预检（F9）：state != released 的租约评论已存在即拒绝——
      # 重复认领判定的两种归宿（§5.2 + 续篇 F1/F4）：
      # - 本地记录处于 claiming/aborted，且凭据身份能对上（lease_id 或评论
      #   id 与记录一致）→ 恢复路径：复用既有凭据继续认领（不重发、不双开）；
      # - 否则（无本地归属/已释放）→ 有主凭据即拒绝，fail-closed。
      prior = record.load
      comments = gateway.issue_comments(issue.number)
      existing = Lease.active_lease(comments, author_whitelist: whitelist)
      adopted = nil
      if existing
        recoverable = prior && %w[claiming aborted].include?(prior["phase"]) &&
                      prior["branch"] == existing["branch"] &&
                      lease_identity_matches?(prior, existing, comments)
        unless recoverable
          payload["ok"] = false
          payload["claim"] = "refused"
          payload["reasons"] = ["issue ##{issue.number} 已持有有效租约（lease_id=#{existing["lease_id"].inspect}），且无可对账的本机记录，禁止重复认领"]
          return EXIT_REFUSED
        end
        adopted = existing
      end

      # 活状态复查（#306）：目标卡已 status=执行中且无可对账的本机认领，
      # 说明它被旧式/手工认领占有，不重复开工。恢复路径（adopted）放行：
      # 半途崩溃的认领可能已写过 status，续做正是恢复的职责。
      unless adopted
        live_status = gateway.status_of(issue.number).to_s
        if Model::WORKING_STATUSES.any? { |name| live_status.casecmp?(name) }
          payload["ok"] = false
          payload["claim"] = "refused"
          payload["reasons"] = ["issue ##{issue.number} 已是 #{live_status} 且无可对账的本机认领，禁止重复认领"]
          return EXIT_REFUSED
        end
      end

      generated_lease_id = adopted ? adopted["lease_id"] : Lease.new_lease_id
      claimed_at = Time.now.utc.iso8601
      payload["run_record"] = record.save({
        "issue" => issue.number,
        "branch" => "feat/#{issue.number}",
        "phase" => "claiming",
        "attempts" => 0,
        # coordinator 串行认领（§5.2）：lease_id 生成后先落记录再发评论——
        # 崩溃后按它检索复用既有评论，不会留下第二份有效凭据。
        # 恢复路径复用既有凭据的 lease_id（补记评论 id 由下方回填）。
        "lease_id" => generated_lease_id,
        "scope" => issue.respond_to?(:automation) && issue.automation.is_a?(Hash) ? issue.automation["scope"] : nil,
        "base_sha" => snap.main_sha,
        "coordinator_id" => ENV["SEBAS_COORDINATOR_ID"] || Socket.gethostname,
        "host" => Socket.gethostname,
        "claimed_at" => claimed_at,
        # F5：认领成功即写首个心跳，之后由 `heartbeat` 子命令续写。
        # 没有这个起点，`heartbeat_expired?` 的「缺字段不判过期」会让新卡
        # 永远不进入失联判定。
        "last_heartbeat_at" => claimed_at
      })

      # 逐步留痕（CR-2/CR-3）：每步成功即更新对应标志，失败落 aborted 时
      # 能精确说明远端推进到了哪一步。
      record_saved = true
      comment_created = false
      status_written = false
      label_written = false
      confirmed = false
      begin
        # 发租约评论：先按生成的 lease_id 检索既有评论（评论已发出而 id 未
        # 落盘的崩溃窗口），找到就复用；没有才发。随后把评论 id 补记为租约 id。
        reused = Lease.find_by_lease_id(gateway.issue_comments(issue.number), generated_lease_id,
          author_whitelist: whitelist)
        if reused
          comment_created = true
          comment_id, _credential = reused
        else
          body = Lease.comment_body(
            lease_id: generated_lease_id, issue: issue.number, branch: "feat/#{issue.number}",
            base_sha: snap.main_sha, coordinator_id: payload["run_record"]["coordinator_id"],
            host: payload["run_record"]["host"], claimed_at: claimed_at
          )
          posted = gateway.create_comment(issue.number, body, allow_write: true)
          comment_id = posted.is_a?(Hash) ? posted["id"] : nil
          comment_created = true
        end
        payload["run_record"] = record.save(payload["run_record"].merge("lease_id" => comment_id || generated_lease_id))

        gateway.set_status(issue.number, Model::STATUS_IN_PROGRESS, allow_write: true)
        status_written = true
        gateway.add_label(issue.number, Model::IN_PROGRESS_LABEL, allow_write: true)
        label_written = true

        # 状态不是分布式事务：写后必须回读，只有回读确认才算 claimed。
        confirmed = gateway.status?(issue.number, Model::STATUS_IN_PROGRESS) &&
                    gateway.label_present?(issue.number, Model::IN_PROGRESS_LABEL) &&
                    lease_readback_confirmed?(gateway, issue.number, whitelist, payload["run_record"])
      rescue CommandError => e
        payload["reasons"] = ["认领写入失败：#{e.message}"]
        confirmed = false
      end

      if confirmed
        payload["run_record"] = record.save(payload["run_record"].merge("phase" => "claimed"))
        payload["claim"] = "claimed"
      else
        # 写入成功但回读失败时保留不确定性，恢复流程不能假设远端没有被推进。
        # lease_id 保留在记录里：恢复按它对账凭据（续篇 F1–F4），而不是重发评论。
        payload["run_record"] = record.save(
          payload["run_record"].merge("phase" => "aborted", "status_written" => status_written,
                                      "label_written" => label_written)
        )
        payload["ok"] = false
        payload["claim"] = "claim_aborted"
        payload["reasons"] ||= []
        payload["reasons"] << "认领步骤未全部确认：" \
          "record=#{record_saved} comment=#{comment_created} status=#{status_written} " \
          "label=#{label_written} readback=#{confirmed}；远端可能已推进，恢复按 lease_id 对账"
      end

      payload["ok"] ? EXIT_OK : EXIT_REFUSED
    end

    # 租约身份对账（CR-1）：记录里的 lease_id 必须能绑定到该凭据——
    # 要么等于凭据 body 的 lease_id，要么等于承载该凭据的评论 id。
    # 只比 phase+branch 不能区分同卡的多份历史租约。
    def lease_identity_matches?(record, credential, comments)
      lease_id = record["lease_id"].to_s
      return false if lease_id.empty?

      credential["lease_id"].to_s == lease_id ||
        comments.any? do |comment|
          comment["id"].to_s == lease_id && comment["body"].to_s.include?(credential["lease_id"].to_s)
        end
    end

    # 释放租约凭据（F12 + CR-4）：本地记录缺失或缺 lease_id 时也必须核对
    # 远端租约——认领成功后丢本地记录，卡上凭据仍要置 released。
    # state 置 released 并回读唯一性（F9 判据不变）；对账不上 → aborted。
    def release_lease_comment!(gateway, issue_number, record, payload)
      lease_id = record && record["lease_id"]
      comments = gateway.issue_comments(issue_number)

      found = lease_id && Lease.find_by_lease_id(comments, lease_id,
        author_whitelist: gateway.coordinators)
      unless found
        # 记录 lease_id 对不上账：退回「按卡扫描有效凭据」——有则按凭据释放，
        # 无则确认卡上确实没有凭据（可能从未认领或已释放），放行收尾。
        credential = Lease.active_lease(comments, author_whitelist: gateway.coordinators)
        if credential
          lease_id = credential["lease_id"]
          found = [credential["lease_id"], credential]
        else
          return payload
        end
      end
      comment_id, credential = found
      unless credential["state"] == Lease::STATE_RELEASED
        body = Lease.comment_body(
          lease_id: lease_id, issue: issue_number, branch: credential["branch"],
          base_sha: credential["base_sha"], coordinator_id: credential["coordinator_id"],
          host: credential["host"], claimed_at: credential["claimed_at"],
          state: Lease::STATE_RELEASED
        )
        gateway.update_comment(comment_id, body, allow_write: true)
      end
      remaining = Lease.active_lease(gateway.issue_comments(issue_number),
        author_whitelist: gateway.coordinators)
      return payload if remaining.nil?

      payload["reasons"] = ["租约释放后仍存在有效凭据，需人工核对"]
      payload["status"] = "aborted"
      payload
    end

    # 租约回读确认（Q1=B + CR-5）：回读必须绑定到**当前有效凭据**——
    # 记录里的 lease_id 要么等于有效凭据 body 的 lease_id，要么等于承载
    # 有效凭据的那条评论的 id。已释放评论的 id 不算数（state 非 active）。
    def lease_readback_confirmed?(gateway, number, whitelist, record)
      lease_id = record["lease_id"].to_s
      return false if lease_id.empty?

      comments = gateway.issue_comments(number)
      credential = Lease.active_lease(comments, author_whitelist: whitelist)
      return false unless credential

      credential["lease_id"] == lease_id ||
        comments.any? do |comment|
          comment["id"].to_s == lease_id &&
            comment["body"].to_s.include?(%Q{"lease_id": "#{credential["lease_id"]}"}) &&
            comment["body"].to_s.include?('"state": "active"')
        end
    rescue InvalidPlan
      # 多份凭据/作者越权/凭据被篡改：fail-closed，交恢复路径人工核对
      false
    end

    # 认领目标仓库必须与校验所用快照一致；否则会写入另一仓库。
    def claim_write_repo(snap, options)
      if snap.repo.to_s.empty?
        raise UsageError, "快照缺 repo 字段，无法确定写入仓库"
      end
      if options[:repo] && options[:repo] != snap.repo
        raise UsageError, "--repo #{options[:repo]} 与快照仓库 #{snap.repo} 不一致"
      end

      snap.repo
    end

    # 认领前的完整校验：卡片状态、标签、kind，再算依赖。
    def claimability(issue, snap)
      blocker = claim_blocker(issue, snap)
      return blocker if blocker

      automation = Policy::Dependencies.automation_for(issue)
      return Model::Evaluation.new(status: "invalid", reasons: ["##{issue.number} 缺 Automation 块"]) unless automation

      Policy::Dependencies.evaluate(issue.with(automation: automation), snap)
    rescue InvalidPlan => e
      Model::Evaluation.new(status: "invalid", reasons: [e.message])
    end

    def claim_blocker(issue, snap)
      reasons = []
      reasons << "##{issue.number} 不是 open 卡" unless issue.open?
      reasons << "##{issue.number} 挂着 #{Model::HUMAN_LABEL}" if issue.label?(Model::HUMAN_LABEL)
      reasons << "##{issue.number} 标为 #{Model::INVALID_LABEL}" if issue.label?(Model::INVALID_LABEL)
      return Model::Evaluation.new(status: "invalid", reasons: reasons) unless reasons.empty?

      others = snap.in_progress_issues.reject { |item| item.number == issue.number }
      if others.length >= snap.capacity
        if snap.capacity == 1 && others.length == 1
          # 试点豁免（M4x-Parallel-WP2，#220 §8 阶段 2）：两张 docs-only 工作包
          # 卡可由 coordinator 并行持有——所有权由各自 per-issue lease 管理，
          # scope 冲突由预算判定；其余仍全仓同时只允许一张。
          return Model::Evaluation.new(status: "invalid",
            reasons: ["已有活动认领 ##{others.first.number}，全仓同时只允许一张"]) unless pilot_docs_pair?(issue, others.first, snap)
        else
          # 容量 >1（recovery §5 / Q3，.github/agents.yml `capacity` 键）：
          # 在途卡数达到容量即拒绝；试点豁免仅在容量 1 的单卡试点下生效。
          return Model::Evaluation.new(status: "invalid",
            reasons: ["已有 #{others.length} 张活动认领（#{others.map(&:number).join("、")}），达到容量 #{snap.capacity}"])
        end
      end

      open_pr = snap.pull_requests.select(&:open?).find { |pr| pr.closing_issues.include?(issue.number) }
      if open_pr
        return Model::Evaluation.new(status: "invalid",
          reasons: ["##{issue.number} 已有 open PR ##{open_pr.number}，禁止重复开工"])
      end

      automation = begin
        Policy::Dependencies.automation_for(issue)
      rescue InvalidPlan => e
        return Model::Evaluation.new(status: "invalid", reasons: [e.message])
      end
      return Model::Evaluation.new(status: "invalid", reasons: ["##{issue.number} 缺 Automation 块"]) unless automation

      # scope 冲突预算（§6.1 / Q4=A）：容量还有空位也必须过这一关。
      # claim 是绕过 plan 的人工入口，口径必须与 plan 一致，否则「plan 说不能并行、
      # claim 硬认领」就成了绕过预算的后门。
      scope_blocker = scope_conflict_blocker(issue.with(automation: automation), snap)
      return scope_blocker if scope_blocker

      if %w[tracking manual].include?(automation["kind"])
        return Model::Evaluation.new(status: "invalid",
          reasons: ["##{issue.number} 的 kind=#{automation["kind"]}，不可认领"])
      end

      # 无 milestone 的卡只有独立小修可以认领。否则等于绕开 milestone 容量与 DAG 检查。
      # 必须用已解析的 automation 构造，快照里 issue.kind 可能尚未回填。
      claimable = issue.with(automation: automation)
      unless claimable.scheduled? || claimable.small_fix?
        return Model::Evaluation.new(status: "invalid",
          reasons: ["##{issue.number} 无 milestone 且不是独立小修（需 type=Task、kind=work_package、depends_on=[]），不可认领"])
      end

      nil
    end

    # scope 冲突预算的 claim 侧判定。容量为 1 且无在途租约时恒放行
    # （与单卡行为一致）；容量 1 + 单张 docs 试点由 pilot_docs_pair? 另行豁免。
    def scope_conflict_blocker(issue, snap)
      others = snap.in_progress_issues.reject { |item| item.number == issue.number }
      return nil if others.empty?

      scope = issue.automation.is_a?(Hash) ? issue.automation["scope"] : nil
      reason, other = Policy::Scope.blocking_lease(scope, Policy::Scope.leases_of(others))
      return nil unless reason

      Model::Evaluation.new(status: "invalid",
        reasons: ["##{issue.number} 不能与在途 ##{other} 并行：#{reason}"])
    end

    # 试点并行判定（M4x-WP2，#220 §8 阶段 2）：两张卡都是 docs-only 工作包
    # （kind=work_package 且 scope 全在 docs/ 下）时允许 coordinator 并行持有，
    # 所有权由各自 lease 凭据管理；任一卡不是 docs-only → 不豁免。
    # CR-14/15：试点并行上限两张，且两卡 scope 不得重叠（目录不重叠约束）。
    def pilot_docs_pair?(issue, other, snap)
      return false unless docs_only_work_package?(issue) && docs_only_card?(other)

      other_active = snap.in_progress_issues.count { |item| item.number != issue.number }
      return false if other_active >= 2 # 已有两张在途 = 试点容量（2）已满

      begin
        my_scope = Policy::Scope.normalize(docs_scope_of(issue), issue_number: issue.number)
        other_scope = Policy::Scope.normalize(docs_scope_of(other), issue_number: other.number)
      rescue InvalidPlan
        return false
      end
      !Policy::Scope.conflict?(my_scope, other_scope)
    end

    def docs_scope_of(card)
      Policy::Dependencies.automation_for(card)["scope"]
    end

    def docs_only_card?(card)
      automation = Policy::Dependencies.automation_for(card)
      return false unless automation
      return false if %w[tracking manual design].include?(automation["kind"])

      scope = automation["scope"]
      scope.is_a?(Array) && !scope.empty? && scope.all? { |prefix| prefix.start_with?("docs/") }
    end

    def docs_only_work_package?(issue)
      docs_only_card?(issue)
    end

    def parse_number(value, label)
      Integer(value, 10)
    rescue ArgumentError, TypeError
      raise UsageError, "#{label} 必须是数字，收到 #{value.inspect}"
    end

    # §3.4 收口动作：PR 已合并 + issue completed 才允许解除认领。
    # 这是 unclaim 的确定性前置，不满足时 fail-closed，绝不自作主张清锁。
    def run_unclaim(argv)
      return help if argv.include?("--help") || argv.include?("-h")

      options, (number,) = Argv.parse(argv, required: ["issue"])
      target = parse_number(number, "issue")
      snap = snapshot(options)
      issue = snap.issue(target)
      raise UsageError, "issue ##{number} 不在快照内" unless issue

      payload = {
        "ok" => false,
        "dry_run" => !options[:apply],
        "issue" => issue.number,
        "reasons" => []
      }

      unless issue.completed?
        payload["reasons"] << "issue ##{issue.number} 未以 completed 关闭（当前 #{issue.state}/#{issue.state_reason || "-"}）"
      end
      merged_pr = snap.pull_requests.find { |pr| pr.closing_issues.include?(issue.number) && pr.merged? }
      unless merged_pr
        payload["reasons"] << "issue ##{issue.number} 没有已合并的关联 PR"
      end
      # 正常收口后 status 已由 GitHub 自动置为 Done；此时不该再要求「执行中」。
      # 既非执行中也非 Done，说明卡没被真正认领过，释放无意义。
      unless issue.working? || issue.status?(Model::STATUS_DONE)
        payload["reasons"] << "issue ##{issue.number} 既不是执行中也不是 Done（当前 #{issue.status || "未设置"}），无需释放"
      end

      if payload["reasons"].any?
        payload["status"] = "refused"
        Output.emit(payload, out: @out)
        return EXIT_REFUSED
      end

      payload["pr"] = merged_pr.number
      if options[:apply]
        repo = claim_write_repo(snap, options)
        gateway = GithubGateway.new(runner(options), repo: repo)
        # 收口写段同样受跨机 ref 锁保护（#306）：与 claim/mark-review 串行，
        # 防止两台机器同时对同一张卡做收口与状态迁移。
        ref = RefLock.lease_ref(issue.number)
        lock = acquire_ref_lock!(gateway, ref: ref, purpose: "lease", issue: issue.number, payload: payload)
        return EXIT_LOCKED if lock.held?
        payload["lock_takeover"] = lock.previous if lock.previous

        code = nil
        begin
          code = unclaim_write_body!(issue, options, payload, gateway, snap)
        rescue CommandError => e
          payload["ok"] = false
          (payload["reasons"] ||= []) << "收口写段异常：#{e.message}"
          code = EXIT_REFUSED
        ensure
          finalize_lock_release!(gateway, ref, lock, payload)
        end
        # 成功时补齐终态字段；apply 分支只输出一份 JSON 并显式返回实际退出码
        # （#307 二轮 review：不得落入非 apply 分支造成双输出/退出码恒 0）。
        if code == EXIT_OK && !payload["lock_release_failed"]
          payload["ok"] = true
          payload["status"] = "released"
        end
        code = EXIT_REFUSED if payload["lock_release_failed"]
        Output.emit(payload, out: @out)
        return code
      end

      payload["ok"] = true
      payload["status"] = "released"
      Output.emit(payload, out: @out)
      EXIT_OK
    end

    # 收口写段本体：只填 payload、返回退出码，不做输出。
    def unclaim_write_body!(issue, options, payload, gateway, snap)
      # 启动搬迁（Q10=B）：写路径才触发迁移（CR-0 只读路径不迁移）。
      RunRecord.migrate_legacy!(options[:record] || RunRecord::DEFAULT_PATH) unless options[:record]
      # 已完成的卡保持 Done：写回 Todo 会抹掉终态，让看板重新出现待办。
      unless issue.status?(Model::STATUS_DONE)
        gateway.set_status(issue.number, Model::STATUS_TODO, allow_write: true)
        unless gateway.status?(issue.number, Model::STATUS_TODO)
          payload["reasons"] << "写回 status=#{Model::STATUS_TODO} 后回读不符，需人工核对"
          payload["status"] = "aborted"
          return EXIT_REFUSED
        end
      end
      record = options[:record] ? RunRecord.new(path: options[:record]) : RunRecord.new(issue: issue.number)
      current = record.load
      # 释放租约凭据（F12 + CR-4）：本地记录缺失/缺 lease_id 也要核对远端
      # 租约——认领成功后丢本地记录时，卡上凭据仍必须置 released。
      release_lease_comment!(gateway, issue.number, current, payload)
      if payload["status"] == "aborted"
        return EXIT_REFUSED
      end
      # 人类可读信号同步摘除（CR-6）：凭据已释放，卡上不得残留执行中标签。
      # 迁移窗口内的旧认领可能本就没打标签——缺席即无需摘除。
      if gateway.label_present?(issue.number, Model::IN_PROGRESS_LABEL)
        gateway.remove_label(issue.number, Model::IN_PROGRESS_LABEL, allow_write: true)
        if gateway.label_present?(issue.number, Model::IN_PROGRESS_LABEL)
          payload["reasons"] << "移除 #{Model::IN_PROGRESS_LABEL} 后回读仍在，需人工核对"
          payload["status"] = "aborted"
          return EXIT_REFUSED
        end
      end
      # 只更新属于本 issue 的记录：传错 --record 时不能把别张卡的记录改脏。
      record.save(current.merge("phase" => "released")) if current && current["issue"].to_i == issue.number
      EXIT_OK
    end

    def run_resume(argv)
      options, (number,) = Argv.parse(argv, required: ["issue"])
      target = parse_number(number, "issue")
      # CR-12：试点双卡下 runs/ 有多份活动记录——按目标 issue 取对应记录。
      record = record_for(options, issue: target)
      raise InvalidPlan, "无本地运行记录，无法续跑 ##{number}" unless record

      if record["issue"].to_i != target
        raise InvalidPlan, "本地记录属于 ##{record["issue"]}，不是 ##{number}"
      end

      # 续跑必须核对远端仍是自己的认领，否则会把已释放的工作卡当成在途。
      snap = snapshot(options)
      issue = snap.issue(target)
      raise InvalidPlan, "issue ##{number} 不在快照内" unless issue

      unless issue.working?
        raise InvalidPlan, "##{issue.number} 远端 status 不是执行中（当前 #{issue.status || "未设置"}），不能按在途续跑"
      end
      # 容量口径（recovery §5 / Q3）：活动认领数超过有效容量才拒绝；
      # 容量 1 时与原单卡守卫语义一致。
      others = snap.in_progress_issues.reject { |item| item.number == issue.number }
      if others.length >= snap.capacity
        raise InvalidPlan, "已有 #{others.length} 张活动认领（#{others.map(&:number).join("、")}），达到容量 #{snap.capacity}"
      end
      raise InvalidPlan, "##{issue.number} 已关闭" unless issue.open?

      payload = {
        "ok" => true,
        "dry_run" => !options[:apply],
        "issue" => record["issue"],
        "phase" => record["phase"],
        "worktree" => record["worktree"],
        "action" => "resume_issue"
      }
      if options[:apply]
        # CR-7/CR-16：显式 --record 优先；记录 Hash 与 RunRecord 对象分变量
        # 保存，避免对象覆盖记录数据。缺省写回该卡自己的 per-issue 路径，
        # 不与他卡记录交叉。
        target_record = options[:record] ? RunRecord.new(path: options[:record]) : RunRecord.new(issue: record["issue"])
        payload["run_record"] = target_record.save(record.merge("phase" => "claimed"))
      end
      Output.emit(payload, out: @out)
      EXIT_OK
    end

    def run_verify(argv)
      kind = argv.first
      case kind
      when "docs" then verify_docs(argv.drop(1))
      when "anchors" then verify_anchors(argv.drop(1))
      when "merge" then verify_merge(argv.drop(1))
      when /\A\d+\z/ then verify_merge(argv) # #124：`verify <pr> <issue>` 直达 merge 语义
      else
        raise UsageError, "verify 子命令：docs <path...> | anchors <json> | merge <pr> <issue>"
      end
    end

    # 提 PR 后把 issue 从 In progress 推进到 In review；合并不经过这里（关闭自动置 Done）。
    def run_mark_review(argv)
      return help if argv.include?("--help") || argv.include?("-h")

      options, (number,) = Argv.parse(argv, required: ["issue"])
      snap = snapshot(options)
      issue = snap.issue(parse_number(number, "issue")) or raise UsageError, "issue ##{number} 不在快照内"
      pr = snap.pull_requests.select(&:open?).find { |item| item.closing_issues.include?(issue.number) }
      reasons = []
      reasons << "##{issue.number} 不是 open 卡" unless issue.open?
      # 只允许从 In progress 进入 In review：跳过认领会把未开工的卡说成在评审。
      unless issue.status?(Model::STATUS_IN_PROGRESS)
        reasons << "##{issue.number} 当前 status=#{issue.status || "未设置"}，只有 In progress 才能推进到 In review"
      end
      reasons << "##{issue.number} 没有关联的 open PR" unless pr

      payload = {"ok" => reasons.empty?, "dry_run" => !options[:apply],
                 "issue" => issue.number, "status" => Model::STATUS_IN_REVIEW, "reasons" => reasons}
      payload["pr"] = pr.number if pr
      if options[:apply] && reasons.empty?
        gateway = GithubGateway.new(runner(options), repo: claim_write_repo(snap, options))
        # 状态迁移写段受跨机 ref 锁保护（#306）：与 claim/unclaim 对同一张卡串行。
        ref = RefLock.lease_ref(issue.number)
        lock = acquire_ref_lock!(gateway, ref: ref, purpose: "lease", issue: issue.number, payload: payload)
        return EXIT_LOCKED if lock.held?
        payload["lock_takeover"] = lock.previous if lock.previous

        code = nil
        begin
          # 锁内重查前置（#307 二轮 review）：快照是锁前取的，B 可能在 A 等锁
          # 期间完成合并收口——已关闭/Done/PR 已合并的卡不得写回 In review。
          state = gateway.issue_state(issue.number)
          unless state == "open"
            payload["ok"] = false
            payload["reasons"] << "锁内复核：issue ##{issue.number} 已不是 open（state=#{state}），不推进 In review"
            code = EXIT_REFUSED
          end
          if code.nil?
            live = gateway.status_of(issue.number).to_s
            unless live.casecmp?(Model::STATUS_IN_PROGRESS)
              payload["ok"] = false
              payload["reasons"] << "锁内复核：issue ##{issue.number} 当前 status=#{live || "未设置"}，不再是 In progress，不推进 In review"
              code = EXIT_REFUSED
            end
          end
          if code.nil?
            pr_state = gateway.pull_state(pr.number)
            unless pr_state == "open"
              payload["ok"] = false
              payload["reasons"] << "锁内复核：PR ##{pr.number} 已不是 open（state=#{pr_state}），不推进 In review"
              code = EXIT_REFUSED
            end
          end
          if code.nil?
            gateway.set_status(issue.number, Model::STATUS_IN_REVIEW, allow_write: true)
            confirmed = gateway.status?(issue.number, Model::STATUS_IN_REVIEW)
            payload["ok"] = payload["status_written"] = confirmed
            payload["reasons"] << "写入 status=#{Model::STATUS_IN_REVIEW} 后回读未确认，需人工核对" unless confirmed
            code = payload["ok"] ? EXIT_OK : EXIT_REFUSED
          end
        rescue CommandError => e
          payload["ok"] = false
          payload["reasons"] << "状态迁移写段异常：#{e.message}"
          code = EXIT_REFUSED
        ensure
          finalize_lock_release!(gateway, ref, lock, payload)
        end
        code = EXIT_REFUSED if payload["lock_release_failed"]
        Output.emit(payload, out: @out)
        code
      else
        Output.emit(payload, out: @out)
        payload["ok"] ? EXIT_OK : EXIT_REFUSED
      end
    end

    def verify_docs(argv)
      return help if argv.include?("--help") || argv.include?("-h")

      options, paths = Argv.parse(argv, required: ["path"], optional: 100)
      report = Verifier.verify_docs(paths, root: root(options))
      Output.emit(report.to_h.merge("ok" => report.pass?), out: @out)
      report.pass? ? EXIT_OK : EXIT_REFUSED
    end

    def verify_anchors(argv)
      return help if argv.include?("--help") || argv.include?("-h")

      options, (path,) = Argv.parse(argv, required: ["anchors.json"])
      report = Verifier.verify_code_anchors(load_anchors(path), root: root(options))
      Output.emit(report.to_h.merge("ok" => report.pass?), out: @out)
      report.pass? ? EXIT_OK : EXIT_REFUSED
    end

    def load_anchors(path)
      JSON.parse(File.read(path, encoding: "UTF-8"))
    rescue JSON::ParserError => e
      raise UsageError, "anchors 不是合法 JSON：#{path}（#{e.message}）"
    rescue Errno::ENOENT
      raise UsageError, "anchors 文件不存在：#{path}"
    end

    def verify_merge(argv)
      return help if argv.include?("--help") || argv.include?("-h")

      options, (pr, issue) = Argv.parse(argv, required: %w[pr issue])
      # fail-fast：终验缺输入文件在访问任何外部资源前就拒绝。
      if options[:final] && !(options[:report] && options[:fixes])
        raise UsageError,
          "--final 需要配 --report <verification.json>（阶段一产物）与 --fixes <fixes.json>"
      end

      if options[:final]
        # 终验是独立阶段（#124）：只读阶段一产出的 verification.json 与 fixes.json，
        # 不以本次现场核验结果为输入——否则前阶段的应修项清单进不了终验，
        # 「--pre --final + 空 fixes」就能借当场全绿蒙混过关。
        report, extra = run_final_verification(options, pr, issue)
        payload = report.to_h.merge(extra).merge("ok" => report.pass?, "pre" => false)
      else
        # 目标 PR 的 CI 单独补取：清单已不带 rollup，不补就只能是「未取」。
        pr_number = parse_number(pr, "pr")
        report = Verifier.verify_merge(pr_number, parse_number(issue, "issue"),
          snapshot(options, verified_pr: pr_number), pre: options[:pre])
        payload = report.to_h.merge("ok" => report.pass?, "pre" => options[:pre] ? true : false)
      end
      Output.emit(payload, out: @out)
      report.pass? ? EXIT_OK : EXIT_REFUSED
    end

    # 终验（#124）：checker 必填且真实复跑——前阶段报告里 evidence 形如命令的
    # must_fix 条目逐项重执行，无可复跑检查的条目直接打回。
    # 自报 passed:true 不再构成「有条件通过」。
    def run_final_verification(options, pr, issue)
      verifier_report = load_report(options[:report])
      fixes = load_fixes(options[:fixes])
      root = root(options)
      checker = ->(item, fix) { VerifyChecks.rerun(item, fix, root: root) }
      final = Verifier.final_verification(verifier_report, fixes, checker: checker)
      # 终验对象随报告落盘可追溯：把 pr/issue 带进输出。
      [final, {"pr" => parse_number(pr, "pr"), "issue" => parse_number(issue, "issue")}]
    end

    def load_fixes(path)
      data = JSON.parse(File.read(path, encoding: "UTF-8"))
      raise UsageError, "--fixes 必须是 JSON 对象：#{path}" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError => e
      raise UsageError, "--fixes 不是合法 JSON：#{path}（#{e.message}）"
    rescue Errno::ENOENT
      raise UsageError, "--fixes 文件不存在：#{path}"
    end

    # 阶段一产物（verification.json）→ 报告对象。未知 level 不静默丢弃：
    # 「没看懂」不能被当成「通过」。
    def load_report(path)
      data = JSON.parse(File.read(path, encoding: "UTF-8"))
      raise UsageError, "Verifier 报告必须是 JSON 对象：#{path}" unless data.is_a?(Hash)

      items = data["items"]
      raise UsageError, "Verifier 报告缺 items 数组：#{path}" unless items.is_a?(Array)

      report = VerificationReport.new
      items.each_with_index do |item, index|
        level = ""
        message = ""
        evidence = nil
        item_id = nil
        if item.is_a?(Hash)
          raw = item["level"].to_s
          raw = item["verdict"].to_s if raw.empty?
          level = VerificationReport::VERDICTS.fetch(raw.strip, "")
          message = item["message"].to_s
          evidence = item["evidence"]
          item_id = item["id"]
        end
        case level
        when "blocker" then report.blocker(message, evidence: evidence, id: item_id)
        when "must_fix" then report.must_fix(message, evidence: evidence, id: item_id)
        when "acceptable" then report.acceptable(message, evidence: evidence, id: item_id)
        when "unverified" then report.unverified(message, evidence: evidence, id: item_id)
        when "ok" then report.ok(message, evidence: evidence)
        else
          raise UsageError,
            "Verifier 报告第 #{index + 1} 项 level 非法：#{item.is_a?(Hash) ? item["level"].inspect : item.inspect}" \
            "（允许 blocker/must_fix/acceptable/unverified/ok，或中英文对应 verdict）"
        end
      end
      report
    rescue JSON::ParserError => e
      raise UsageError, "Verifier 报告不是合法 JSON：#{path}（#{e.message}）"
    rescue Errno::ENOENT
      raise UsageError, "Verifier 报告不存在：#{path}"
    end

    def run_triage(argv)
      return help if argv.include?("--help") || argv.include?("-h")

      options, (number,) = Argv.parse(argv, required: ["issue"])
      verdict = options[:verdict] ? load_verdict(options[:verdict]) : nil
      issue_number = parse_number(number, "issue")
      snap = snapshot(options, proposal_issue: issue_number)
      issue = snap.issue(issue_number)
      raise UsageError, "issue ##{number} 不在快照内" unless issue

      plan = Triager.plan(issue, snap, verdict: verdict)
      payload = plan.merge("dry_run" => !options[:apply])
      payload["comment_preview"] = plan["comment"] if plan["comment"]
      Output.emit(payload, out: @out)
      plan["ok"] ? EXIT_OK : EXIT_REFUSED
    end

    def load_verdict(path)
      data = JSON.parse(File.read(path, encoding: "UTF-8"))
      raise UsageError, "--verdict 必须是 JSON 对象：#{path}" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError => e
      raise UsageError, "--verdict 不是合法 JSON：#{path}（#{e.message}）"
    rescue Errno::ENOENT
      raise UsageError, "--verdict 文件不存在：#{path}"
    end

# Proposal 处理：把散落的研判评论压成一条置顶索引。
# 默认 dry-run；--apply 才写评论与置顶。人工摘要区在标记之后，工具永不覆盖。
#
# 不读全仓快照：digest 只需要目标 issue 与它的评论。走 snapshot 会拉全仓
# PR/milestone/依赖闭包（PR 清单已改 GraphQL 游标分页，无单页截断面）。
def run_digest(argv)
  return help if argv.include?("--help") || argv.include?("-h")

  options, (number,) = Argv.parse(argv, required: ["issue"])
  target = parse_number(number, "issue")
  repo = options[:repo] || default_repo
  gateway = GithubGateway.new(runner(options), repo: repo)

  raw = gateway.fetch_issue(target)
  raise UsageError, "##{target} 不是 Proposal（缺 proposal 标签且 type 不是 Proposal）" unless raw.proposal?

  comments = gateway.issue_comments(target)
  existing = Digest.existing(comments)
  manual_before = existing && Digest.manual_section(existing["body"])
  body = Digest.build({"number" => raw.number, "title" => raw.title}, comments,
    existing_body: existing && existing["body"])

  payload = {
    "ok" => true,
    "dry_run" => !options[:apply],
    "issue" => raw.number,
    "comment" => existing ? "update" : "create",
    "judgments" => comments.count { |comment| Digest.status_of(comment["body"]) && Digest.jarvis?(comment["body"]) },
    "pinned" => !gateway.pinned_comment(target).nil?
  }

  if options[:apply]
    comment = existing ? update_with_conflict_check(gateway, target, existing, manual_before, body) : create_digest(gateway, target, body)
    pinned = gateway.pinned_comment(target)
    gateway.pin_comment(comment["node_id"], allow_write: true) if pinned.nil? || pinned["id"] != comment["id"]
    payload["comment_id"] = comment["id"]
    payload["pinned"] = true
    payload["digest_url"] = comment["html_url"]
  end

  Output.emit(payload, out: @out)
  EXIT_OK
end

# 写入前重读：人工区在读与写之间被改过就中止，避免用旧摘要覆盖新摘要。
# 接口不支持条件写入，只能缩小窗口，不能完全消除竞争。
def update_with_conflict_check(gateway, target, existing, manual_before, body)
  fresh = gateway.issue_comments(target).find { |item| item["id"] == existing["id"] }
  raise UsageError, "##{target} 的摘要评论已消失，请重跑 digest" if fresh.nil?

  if Digest.manual_section(fresh["body"]) != manual_before
    raise UsageError,
      "##{target} 的人工摘要区在本次运行期间被修改，已中止写入以免覆盖；请重跑 digest"
  end

  gateway.update_comment(existing["id"], body, allow_write: true)
  existing
end

# 创建不做盲目重试：评论创建非幂等，超时后重试会写出第二条摘要。
# 失败时交由调用方重跑（重跑会走 update 分支，天然去重）。
def create_digest(gateway, target, body)
  created = gateway.create_comment(target, body, allow_write: true)
  JSON.parse(created)
rescue CommandError => e
  raise CommandError.new(
    "创建摘要评论结果未知（#{e.message}）；请重跑 digest——已创建时会走更新分支",
    command: e.command
  )
end

    def run_docs_check(argv)
      options, = Argv.parse(argv)
      # check_docs.rb 在 tools/ 下，不在 lib/；这里的相对层级是 tools/agents/lib/sebas_agents → tools/
      require_relative "../../../check_docs"
      code = CheckDocs.run(["--root", File.join(root(options), "docs")], repo_root: root(options),
        out: @out, err: @err)
      code.zero? ? EXIT_OK : EXIT_REFUSED
    end

    def run_release(argv)
      action = argv.first
      case action
      when "plan" then release_plan(argv.drop(1))
      when "verify" then release_verify(argv.drop(1))
      else raise UsageError, "release 子命令：plan | verify <version>"
      end
    end

    def release_plan(argv)
      options, = Argv.parse(argv)
      git = CommandRunner.new(dry_run: !options[:apply])
      latest = git.run!("git", "describe", "--tags", "--abbrev=0").strip
      raise CommandError.new("仓库没有 tag，无法计算 patch 版本", command: ["git", "describe"]) if latest.empty?

      subjects = git.run!("git", "log", "--format=%s", "#{latest}..HEAD")
        .lines.map(&:strip).reject(&:empty?)
      Output.emit(Release.plan(latest_tag: latest, subjects: subjects), out: @out)
      EXIT_OK
    end

    def release_verify(argv)
      options, (version,) = Argv.parse(argv, required: ["version"])
      raise UsageError, "缺少 --root（产物目录）" unless options[:root]

      problems = Release.verify_assets(root(options), version.delete_prefix("v"))
      Output.emit({"ok" => problems.empty?, "version" => version, "problems" => problems}, out: @out)
      problems.empty? ? EXIT_OK : EXIT_REFUSED
    end

    def run_roles(argv)
      options = {}
      role = nil
      argv.each do |item|
        case item
        when "--one-line", "--oneline" then options[:oneline] = true
        when "--prompt-only" then options[:prompt_only] = true
        when "--json" then options[:json] = true
        when /\A-/ then raise UsageError, "roles 不支持选项 #{item}"
        else
          raise UsageError, "roles 只接受一个角色名" if role

          role = item
        end
      end

      if options[:oneline]
        if role.nil?
          RolePrompts::ROLES.each { |name| @out.puts(RolePrompts.oneline(name)) }
          return EXIT_OK
        end

        @out.puts(RolePrompts.oneline(role))
        return EXIT_OK
      end

      if options[:prompt_only]
        raise UsageError, "roles --prompt-only 需要角色名" unless role

        @out.puts(RolePrompts.prompt(role))
        return EXIT_OK
      end

      if role.nil?
        Output.emit({"roles" => RolePrompts.all.transform_values { |item| item.except("prompt") }}, out: @out)
      elsif options[:json]
        Output.emit(RolePrompts.writeup(role), out: @out)
      else
        writeup = RolePrompts.writeup(role)
        @out.puts("# #{writeup["role"]}")
        @out.puts("spec: #{writeup["spec"]}")
        @out.puts("access: #{writeup["access"]}")
        @out.puts("一句话：#{writeup["oneline"]}")
        @out.puts
        @out.puts(writeup["prompt"])
      end
      EXIT_OK
    end

    def version_payload
      {"name" => "sebas-process", "version" => SebasAgents::VERSION}
    end

    def help
      @out.puts(<<~TEXT)
        sebas-process —— 按 docs/design/process 角色流程执行的确定性工具

        用法：ruby tools/sebas-process <命令> [选项]

        Implementer
          next            读取 GitHub，输出单一动作（默认只读）
          plan            只读多候选视图：全部就绪候选 + 枚举排除集 + 逐租约动作（#218/#221）
          queue           只读合并队列：队首 PR 与它在合并链上的下一步（#221）
                          --apply 推进队首一步（#221）；--auto --apply 自动触发
                          （#222）：auto_merge_enabled 开启时条件齐备即自动推进
                          （不加 --apply 只做 dry-run），verify_pre 通过后同一轮
                          接续；「有条件通过」（可信 verifier 摘要 unverified>0）
                          与连续自动失败达 2 次都停轮交人工
          heartbeat <issue> [--pid <worker pid>] [--ttl <秒>] [--apply]
                          写存活心跳（F5）。--apply 才写，且此时 --pid 必填：
                          它必须是 worker 自己的 pid（别用 shell 的 $$）。
                          只读模式不给 --pid 也能用：--ttl <秒> 返回是否已过期；
                          写入结果不附过期判定。--ttl 只作判据提示，不写入记录
                          （阈值属全局策略，按卡配置会变成「谁喊得久谁不死」）。
          claim <issue>   校验并认领一张卡；--apply 才写本地记录
          resume <issue>  续跑本机已认领卡；--apply 写回 phase
          unclaim <issue> 收口后释放认领；要求 PR 已合并且 issue completed
          mark-review <issue>  提 PR 后推进 status 到 In review；--apply 才写远端

        Verifier（只读；核验与终验两阶段）
          verify docs <path...>
          verify anchors <anchors.json>
          verify merge <pr> <issue>         合并后完整性核验（要求已合并 + issue completed）
          verify merge <pr> <issue> --pre   合并前自检（跳过合并/关闭两条，只查 CI 与关联）
          verify merge <pr> <issue> --final --report <verification.json> --fixes <fixes.json>
                                            终验（独立阶段）：读阶段一报告，must_fix 逐项复跑 checker（#124）

        Triager / Scribe / Release Manager
          triage <issue> [--apply]
          digest <issue>  Proposal 置顶索引：汇总研判时间线；--apply 才写远端
          docs-check
          release plan
          release verify <version> --root <artifact-dir>

        引导
          roles                  列出全部角色、规格与命令
          roles <role>           人读：规格 + 权限 + 一句话 + 提示词
          roles --one-line       全部角色的一句话开工文本（直接粘贴）
          roles <role> --one-line      该角色的一句话开工文本
          roles <role> --prompt-only   纯文本完整提示词
          roles <role> --json    机器读：结构化字段

        通用选项
          --repo OWNER/NAME  默认取 origin，或 SEBAS_REPO
          --snapshot PATH    离线快照（不访问 GitHub）
          --record PATH      本地运行记录，默认 .sebas-agent/run.json
          --verdict PATH     triage 的模型判定 JSON
          --apply            允许写操作；默认 dry-run
          --dry-run          显式只读（默认即此）
          --root PATH        仓库根或产物目录
          --json PATH        triage 的输入；roles 用 --json 输出结构化
          --fixes PATH       verify --final 的修复清单
          --report PATH      verify --final 的阶段一报告（verification.json）
          --final            verify merge 终验开关（需配 --report 与 --fixes）

        退出码：0 允许 / 1 门禁拒绝 / 2 用法或环境错误
      TEXT
      EXIT_OK
    end
  end
end
