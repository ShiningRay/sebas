# frozen_string_literal: true

# 两阶段 Evidence 登记（#126）。
#
# 背景：Evidence 原先只在 PR 合并后登记，而 `verify merge --pre` 要求合并前
# 就必须存在 → 每个新 PR 必然打回，历史上 #112/#117/#118/#119/#120 全部靠人工豁免。
#
# 解法（Maintainer 选定「先登记后更新」）：
#   1. 合并前：pre_register 写入 merged_into_main=false、merge_commit=null，
#      让门禁有据可依。
#   2. 合并后：upgrade_after_merge 把同一块升级为 merged_into_main=true
#      并填入真实 merge commit，仍由 git 祖先关系证实。
#
# 安全边界：
#   - 合并前登记不得携带 merged_into_main=true（等于伪造合并证据）→ 直接拒绝。
#   - 只有合并后路径能置 true，且必须通过 `git merge-base --is-ancestor`。
#   - 升级保持原块的 untested，不重新读取卡面——登记期已冻结，避免漂移。

module EvidenceRegister
  module TwoPhase
    SUCCESSFUL_CONCLUSIONS = %w[success neutral skipped].freeze
    COMMENT_ID = /#issuecomment-(\d+)\z/

    # 非门禁的第三方审阅 check（如 CodeRabbit）：只表示「本轮审阅进行中」。
    # 本文件被 evidence-register.yml 以 `ruby tools/evidence_register.rb` 直接加载，
    # 不经过 agents 库，因此这里保留一份名单；由
    # test_evidence_register.rb 的 test_advisory_lists_stay_in_sync 锁住与
    # SebasAgents::AdvisoryChecks::NAMES 一致，防止两处漂移。
    ADVISORY_CHECK_NAMES = ["CodeRabbit"].freeze

    # GitHub 只定义这三种 check run 状态。未知取值一律拒绝：advisory 被整类
    # 排除出 gate_runs 后，未知状态既不在 pending 也不进 failed_advisory，
    # 静默放行就把 fail-closed 反过来了（CodeRabbit Minor，PR #243）。
    CHECK_STATUSES = %w[queued in_progress completed].freeze

    module_function

    # 合并前登记。-pre 语义：PR 仍 open、目标 main、CI 全绿、issue 仍 open。
    def pre_register(repo:, pr:, pr_number:, out:)
      if pr["merged_at"]
        out.puts "skip: PR ##{pr_number} 已合并，合并前登记不再适用"
        return 0
      end
      unless pr["state"].to_s.casecmp?("open")
        out.puts "skip: PR ##{pr_number} 状态为 #{pr["state"]}，不是 open"
        return 0
      end
      unless pr.dig("base", "ref").to_s == "main"
        out.puts "skip: PR ##{pr_number} 目标分支不是 main"
        return 0
      end

      issue_number = EvidenceRegister.closing_issue(pr)
      if issue_number.nil?
        out.puts "skip: PR ##{pr_number} 未通过 Fixes #n 关联唯一 issue"
        return 0
      end

      issue = EvidenceRegister.gh_json("repos/#{repo}/issues/#{issue_number}")
      unless issue["state"].to_s.casecmp?("open")
        out.puts "skip: issue ##{issue_number} 不是 open（#{issue["state"]}）"
        return 0
      end

      existing = EvidenceRegister.existing_evidence(issue["body"], subject: "issue:#{issue_number}")
      case existing
      when :invalid
        warn "::error::issue ##{issue_number} 的现有 Evidence 块结构非法，需人工修复后再登记"
        return 1
      when :valid
        block = EvidenceRegister.parse_block(issue["body"].to_s)
        if block && block["merged_into_main"] == true
          # PR 未合并却声称已合并：要么块被手工篡改，要么 PR 已回退。不能默认放行。
          warn "::error::issue ##{issue_number} 的 Evidence 声称 merged_into_main=true，但 PR ##{pr_number} 未合并"
          return 1
        end

        out.puts "skip: issue ##{issue_number} 已有合并前 Evidence（幂等）"
        return 0
      end

      checks_url = pre_checks_url(repo, pr, pr_number, out: out)
      return 1 if checks_url == :failed

      EvidenceRegister.register(
        repo: repo, issue: issue, issue_number: issue_number, pr_number: pr_number,
        merge_commit: nil, checks_url: checks_url, merged_into_main: false, out: out
      )
      0
    end

    # 合并前的「全绿」不能只看「没有失败」：checks 为空说明没取到结果，
    # 此时放行等于把「没看见」当成「通过」。
    #
    # 必须排除本 workflow 自身的 check（#126 实测发现）：evidence-register 的
    # `register evidence` job 也挂在同一 head sha 上，运行时状态是 in_progress、
    # 失败时是 failure。若不排除，预登记会把自己判成「未完成」或「失败」而自我阻塞，
    # 且前一次失败会在重跑时变成新的「失败检查」——永远无法通过。
    SELF_CHECK_NAME = "register evidence"

    def pre_checks_url(repo, pr, pr_number, out:)
      sha = pr.dig("head", "sha").to_s
      if sha.empty?
        out.puts "fail: PR ##{pr_number} 取不到 head sha，无法确认 CI"
        return :failed
      end

      payload = EvidenceRegister.gh_json("repos/#{repo}/commits/#{sha}/check-runs?per_page=100")
      raw = Array(payload["check_runs"])

      # 先校验元数据完整性，再按名排除自身（CodeRabbit）：
      # 若先过滤名称，一条 `{"name":"register evidence"}`（缺 status）会被静默跳过；
      # 缺元数据的记录本身可疑，必须 fail-closed 而不是当作可忽略项。
      malformed = raw.reject do |run|
        run["name"].is_a?(String) && !run["name"].strip.empty? &&
          run["status"].is_a?(String) && !run["status"].strip.empty?
      end
      unless malformed.empty?
        out.puts "fail: PR ##{pr_number} 存在元数据不完整的检查记录（#{malformed.length} 条），拒绝登记"
        return :failed
      end

      runs = raw.reject { |run| run["name"] == SELF_CHECK_NAME }
      if runs.empty?
        out.puts "fail: PR ##{pr_number} 没有任何 CI 检查记录，无法确认全绿"
        return :failed
      end

      # advisory 整类被排除出 gate_runs，未知状态就落不进任何判定分支而静默通过。
      # 必须在这里显式拒绝：GitHub 只定义 queued/in_progress/completed 三态，
      # 出现别的取值说明数据可疑（CodeRabbit Minor，PR #243）。
      unknown = runs.select do |run|
        !CHECK_STATUSES.include?(run["status"].to_s)
      end
      unless unknown.empty?
        out.puts "fail: PR ##{pr_number} 存在状态未知的检查记录（#{unknown.map { |r| "#{r["name"]}=#{r["status"].inspect}" }.join("、")}），拒绝登记"
        return :failed
      end

      # 第三方审阅 check（如 CodeRabbit）在轮次进行中是 in_progress，一轮 4-8 分钟。
      # 它不在分支保护的必需检查里，等它只会让预登记反复失败（实测 PR #237 连续
      # 5 次同因失败）；审阅意见的权威载体是未解决 review thread，由
      # `verify merge --pre` 单独校验。
      #
      # 门禁类检查要排除**全部** advisory（不分状态），否则「只剩一条已完成的
      # CodeRabbit success」会留在 gate_runs 里，把「没看见 CI」判成全绿。
      # 已完成而结论不是成功时仍按失败处理：服务故障 CANCELLED 需人工裁决。
      gate_runs = runs.reject { |run| ADVISORY_CHECK_NAMES.include?(run["name"].to_s) }
      if gate_runs.empty?
        out.puts "fail: PR ##{pr_number} 除第三方审阅外没有任何 CI 检查记录，无法确认全绿"
        return :failed
      end

      pending = gate_runs.reject { |run| run["status"].to_s == "completed" }
      unless pending.empty?
        out.puts "fail: PR ##{pr_number} 仍有未完成的检查：#{pending.map { |r| r["name"] }.join("、")}"
        return :failed
      end

      bad = gate_runs.reject { |run| SUCCESSFUL_CONCLUSIONS.include?(run["conclusion"].to_s) }
      unless bad.empty?
        out.puts "fail: PR ##{pr_number} 存在失败的检查：#{bad.map { |r| r["name"] }.join("、")}"
        return :failed
      end

      failed_advisory = runs.select do |run|
        ADVISORY_CHECK_NAMES.include?(run["name"].to_s) &&
          run["status"].to_s == "completed" &&
          !SUCCESSFUL_CONCLUSIONS.include?(run["conclusion"].to_s)
      end
      unless failed_advisory.empty?
        out.puts "fail: PR ##{pr_number} 的第三方审阅检查失败：#{failed_advisory.map { |r| r["name"] }.join("、")}"
        return :failed
      end

      "#{pr["html_url"]}/checks"
    rescue StandardError => e
      out.puts "fail: 查询 PR ##{pr_number} 的检查记录失败（#{e.message}）"
      :failed
    end

    # 合并后升级：把既有合并前块改写为合并后证据。
    # 先改评论再改正文：评论失败时正文仍是 false，两者一致（都是合并前）。
    #
    # 授权要点（CodeRabbit CWE-345）：untested 必须来自登记评论，不能取 issue 正文副本。
    # 正文可被任何有写权限者编辑；若采信正文，把 untested 改成 [] 并保留 source_ref，
    # 升级就会把 [] 写进受信 bot 的评论，之后 registration_matches? 比对到两份一致的 []
    # → 未实测项被抹除，合并前自检被绕过。
    def upgrade_after_merge(repo:, issue:, issue_number:, pr_number:, merge_commit:, checks_url:, out:)
      block = EvidenceRegister.parse_block(issue["body"].to_s)
      if block.nil?
        warn "::error::issue ##{issue_number} 的 Evidence 块无法解析，需人工修复"
        return 1
      end
      if block["merged_into_main"] == true
        out.puts "skip: issue ##{issue_number} 已有合并后 Evidence（幂等）"
        return 0
      end

      comment_id = comment_id_from(block["source_ref"].to_s)
      if comment_id.nil?
        warn "::error::issue ##{issue_number} 的 source_ref 无法解析评论编号（#{block["source_ref"].to_s[0, 80]}）"
        return 1
      end

      registered = fetch_registered_comment(repo, issue_number, comment_id, block, out)
      return 1 if registered.nil?

      # 登记必须属于本次合并的 PR（CodeRabbit CWE-345 第二点）。
      # 受信作者只证明「谁写了这条评论」，不证明「这条登记属于当前 PR」——
      # 否则 issue 上残留的旧 PR 登记会被本次合并继承其冻结的 untested。
      unless registered["pr"].to_i == pr_number
        warn "::error::issue ##{issue_number} 的登记评论属于 PR ##{registered["pr"].inspect}，与本次合并的 PR ##{pr_number} 不符，拒绝升级"
        return 1
      end

      # 结构必须先完整，再生成升级块：merge 不会补齐缺失字段，
      # 否则两处 PATCH 会写入不完整 Evidence，且 merged_into_main=true 后不再自愈。
      problems = structure_problems(registered)
      unless problems.empty?
        warn "::error::issue ##{issue_number} 的登记评论 Evidence 结构非法：#{problems.join("、")}"
        return 1
      end

      # untested 以登记评论为唯一权威；正文副本只用于结构校验（上面 parse_block）。
      upgraded = registered.merge(
        "pr" => pr_number,
        "merge_commit" => merge_commit,
        "merged_into_main" => true,
        "checks" => checks_url
      )

      EvidenceRegister.gh_json("repos/#{repo}/issues/comments/#{comment_id}",
        method: "PATCH", body: {"body" => EvidenceRegister.render_comment(upgraded)})
      fresh = EvidenceRegister.gh_json("repos/#{repo}/issues/#{issue_number}")
      EvidenceRegister.gh_json("repos/#{repo}/issues/#{issue_number}",
        method: "PATCH", body: {"body" => EvidenceRegister.upsert_evidence_section(fresh["body"], upgraded)})

      out.puts "issue ##{issue_number} Evidence 已升级为合并后（#{merge_commit[0, 8]}）"
      0
    end

    def comment_id_from(url)
      match = COMMENT_ID.match(url.strip)
      match && match[1].to_i
    end

    # 读回 source_ref 指向的登记评论，并核对身份与内容。
    # 返回 comments API 的评论体（含 user.login）解析出的 evidence 块，或 nil（表示拒绝）。
    #
    # 三道核对，任一失败即拒绝：
    #   1. 评论属于本仓库、本 issue（防跨 issue 引用）。
    #   2. 作者在 .github/agents.yml 的 trusted_bots 内。
    #   3. 评论正文自带的 evidence 块与正文副本同 subject。
    def fetch_registered_comment(repo, issue_number, comment_id, body_block, out)
      comment = EvidenceRegister.gh_json("repos/#{repo}/issues/comments/#{comment_id}")
      author = comment.dig("user", "login").to_s

      unless trusted_bot?(author)
        warn "::error::issue ##{issue_number} 的登记评论作者 #{author.inspect} 不在 trusted_bots 内，拒绝升级"
        return nil
      end

      unless comment["issue_url"].to_s.end_with?("/issues/#{issue_number}")
        warn "::error::issue ##{issue_number} 的 source_ref 指向其它 issue（#{comment["issue_url"]}），拒绝升级"
        return nil
      end

      registered = EvidenceRegister.parse_block(comment["body"].to_s)
      if registered.nil?
        warn "::error::登记评论 #{comment_id} 内没有可解析的 evidence 块，拒绝升级"
        return nil
      end

      subject = "issue:#{issue_number}"
      unless registered["subject"].to_s == subject && body_block["subject"].to_s == subject
        warn "::error::登记评论与正文块的 subject 不一致（#{registered["subject"].inspect} / #{body_block["subject"].inspect}），拒绝升级"
        return nil
      end

      registered
    end

    def trusted_bot?(login)
      path = File.join(Dir.pwd, ".github", "agents.yml")
      return false unless File.exist?(path)

      require "yaml"
      data = YAML.safe_load_file(path)
      raw = data && data["trusted_bots"]
      # 结构非法必须拒绝：`trusted_bots: "github-actions[bot]"` 经 Array() 会变成
      # 单元素列表而误授权。只接受字符串数组，且逐项非空。
      unless raw.is_a?(Array) && raw.all? { |entry| entry.is_a?(String) && !entry.strip.empty? }
        warn "::error::.github/agents.yml 的 trusted_bots 必须是字符串数组，按不可信处理"
        return false
      end

      raw.map(&:strip).include?(login)
    rescue StandardError => e
      warn "::error::读取 .github/agents.yml 失败（#{e.message}），按不可信处理"
      false
    end

    REQUIRED_KEYS = %w[schema subject status source source_ref].freeze

    # 登记块结构完整性：merge 只覆盖给定键，缺失字段不会被补齐。
    def structure_problems(block)
      problems = []
      REQUIRED_KEYS.each do |key|
        value = block[key]
        problems << "缺 #{key}" if value.nil? || value.to_s.strip.empty?
      end
      problems << "schema 必须为 #{EvidenceRegister::EVIDENCE_SCHEMA}" unless block["schema"] == EvidenceRegister::EVIDENCE_SCHEMA
      problems << "untested 必须是数组" unless block["untested"].is_a?(Array)
      problems
    end
  end
end
