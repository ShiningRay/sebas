# frozen_string_literal: true

require "json"

module SebasAgents
  # CLI：所有子命令默认 dry-run，只有 --apply 才写远端或本地版本文件。
  class CLI
    EXIT_OK = 0
    EXIT_REFUSED = 1
    EXIT_USAGE = 2

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
      when "claim" then run_claim(argv.drop(1))
      when "resume" then run_resume(argv.drop(1))
      when "verify" then run_verify(argv.drop(1))
      when "review" then run_review(argv.drop(1))
      when "triage" then run_triage(argv.drop(1))
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

    def snapshot(options)
      return load_snapshot(options[:snapshot]) if options[:snapshot]

      repo = options[:repo] || default_repo
      gateway = GithubGateway.new(runner(options), repo: repo)
      gateway.snapshot
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

    def record_for(options)
      RunRecord.new(path: options[:record]).load
    end

    def run_next(argv)
      options, = Argv.parse(argv)
      action = Policy::Selection.select_action(snapshot(options), record: record_for(options))
      Output.emit({"ok" => action.action != "invalid_plan"}.merge(action.to_h), out: @out)
      action.action == "invalid_plan" ? EXIT_REFUSED : EXIT_OK
    end

    def run_claim(argv)
      return help if argv.include?("--help") || argv.include?("-h")

      options, (number,) = Argv.parse(argv, required: ["issue"])
      # 先校验数字，再去访问 GitHub：参数错不该触发网络或仓库探测。
      target = parse_number(number, "issue")
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
        # 快照决定校验对象；写入必须落在同一仓库，否则会认领一张没校验过的卡。
        repo = claim_write_repo(snap, options)
        record = RunRecord.new(path: options[:record])
        payload["run_record"] = record.save({
          "issue" => issue.number,
          "branch" => "feat/#{issue.number}",
          "phase" => "claiming",
          "attempts" => 0
        })

        # 标签不是分布式事务：写后必须回读，只有回读确认才算 claimed。
        # 任何一步出错都要落 aborted，不能让记录停在 claiming。
        gateway = GithubGateway.new(runner(options), repo: repo)
        written = false
        begin
          gateway.add_label(issue.number, Model::IN_PROGRESS_LABEL, allow_write: true)
          written = true
          confirmed = gateway.label_present?(issue.number, Model::IN_PROGRESS_LABEL)
        rescue CommandError => e
          payload["reasons"] = ["认领写入失败：#{e.message}"]
          confirmed = false
        end

        if confirmed
          payload["run_record"] = record.save(payload["run_record"].merge("phase" => "claimed"))
          payload["claim"] = "claimed"
        else
          # 写入成功但回读失败时保留不确定性，恢复流程不能假设远端没有标签。
          payload["run_record"] = record.save(
            payload["run_record"].merge("phase" => "aborted", "label_written" => written)
          )
          payload["ok"] = false
          payload["claim"] = "claim_aborted"
          payload["reasons"] ||= []
          payload["reasons"] << if written
            "写入 #{Model::IN_PROGRESS_LABEL} 后回读未确认；远端状态未知，恢复前需人工核对"
          else
            "写入 #{Model::IN_PROGRESS_LABEL} 失败，未产生远端变更"
          end
        end
      end
      Output.emit(payload, out: @out)
      payload["ok"] ? EXIT_OK : EXIT_REFUSED
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

      other = snap.in_progress_issues.find { |item| item.number != issue.number }
      if other
        return Model::Evaluation.new(status: "invalid",
          reasons: ["已有活动认领 ##{other.number}，全仓同时只允许一张"])
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

      if %w[tracking manual].include?(automation["kind"])
        return Model::Evaluation.new(status: "invalid",
          reasons: ["##{issue.number} 的 kind=#{automation["kind"]}，不可认领"])
      end

      nil
    end

    def parse_number(value, label)
      Integer(value, 10)
    rescue ArgumentError, TypeError
      raise UsageError, "#{label} 必须是数字，收到 #{value.inspect}"
    end

    def run_resume(argv)
      options, (number,) = Argv.parse(argv, required: ["issue"])
      record = record_for(options)
      target = parse_number(number, "issue")
      raise InvalidPlan, "无本地运行记录，无法续跑 ##{number}" unless record

      if record["issue"].to_i != target
        raise InvalidPlan, "本地记录属于 ##{record["issue"]}，不是 ##{number}"
      end

      # 续跑必须核对远端仍是自己的认领，否则会把已释放的工作卡当成在途。
      snap = snapshot(options)
      issue = snap.issue(target)
      raise InvalidPlan, "issue ##{number} 不在快照内" unless issue

      unless issue.label?(Model::IN_PROGRESS_LABEL)
        raise InvalidPlan, "##{issue.number} 远端已无 #{Model::IN_PROGRESS_LABEL}，不能按在途续跑"
      end
      other = snap.in_progress_issues.find { |item| item.number != issue.number }
      raise InvalidPlan, "存在另一张活动认领 ##{other.number}" if other
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
        payload["run_record"] = RunRecord.new(path: options[:record]).save(record.merge("phase" => "claimed"))
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
      else
        raise UsageError, "verify 子命令：docs <path...> | anchors <json> | merge <pr> <issue>"
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
      report = Verifier.verify_merge(parse_number(pr, "pr"), parse_number(issue, "issue"), snapshot(options))
      Output.emit(report.to_h.merge("ok" => report.pass?), out: @out)
      report.pass? ? EXIT_OK : EXIT_REFUSED
    end

    def run_review(argv)
      return help if argv.include?("--help") || argv.include?("-h")

      options, (path,) = Argv.parse(argv, required: ["verification.json"])
      raise UsageError, "缺少 --fixes" unless options[:fixes]

      verifier_report = load_report(path)
      fixes = load_fixes(options[:fixes])
      report = Reviewer.final_verification(verifier_report, fixes)
      Output.emit(report.to_h.merge("ok" => report.pass?), out: @out)
      report.pass? ? EXIT_OK : EXIT_REFUSED
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

    def load_report(path)
      data = JSON.parse(File.read(path, encoding: "UTF-8"))
      raise UsageError, "Verifier 报告必须是 JSON 对象：#{path}" unless data.is_a?(Hash)

      items = data["items"]
      raise UsageError, "Verifier 报告缺 items 数组：#{path}" unless items.is_a?(Array)

      report = VerificationReport.new
      items.each_with_index do |item, index|
        level = item.is_a?(Hash) ? item["level"].to_s : ""
        message = item.is_a?(Hash) ? item["message"].to_s : ""
        case level
        when "blocker" then report.blocker(message, evidence: item["evidence"])
        when "must_fix" then report.must_fix(message, evidence: item["evidence"])
        when "acceptable" then report.acceptable(message, evidence: item["evidence"])
        when "unverified" then report.unverified(message, evidence: item["evidence"])
        when "ok", "pass" then report.ok(message, evidence: item["evidence"])
        else
          # 未知级别不能被静默丢弃，否则会把「没看懂」当成「通过」。
          raise UsageError,
            "Verifier 报告第 #{index + 1} 项 level 非法：#{level.inspect}（允许 blocker/must_fix/acceptable/unverified/ok）"
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
      snap = snapshot(options)
      issue = snap.issue(parse_number(number, "issue"))
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
          claim <issue>   校验并认领一张卡；--apply 才写本地记录
          resume <issue>  续跑本机已认领卡；--apply 写回 phase

        Verifier（只读）
          verify docs <path...>
          verify anchors <anchors.json>
          verify merge <pr> <issue>

        Reviewer（只读）
          review <verification.json> --fixes <fixes.json>

        Triager / Scribe / Release Manager
          triage <issue> [--apply]
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
          --json PATH        triage/review 的输入；roles 用 --json 输出结构化
          --fixes PATH       review 的修复清单

        退出码：0 允许 / 1 门禁拒绝 / 2 用法或环境错误
      TEXT
      EXIT_OK
    end
  end
end
