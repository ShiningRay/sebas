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
    def pre_checks_url(repo, pr, pr_number, out:)
      sha = pr.dig("head", "sha").to_s
      if sha.empty?
        out.puts "fail: PR ##{pr_number} 取不到 head sha，无法确认 CI"
        return :failed
      end

      payload = EvidenceRegister.gh_json("repos/#{repo}/commits/#{sha}/check-runs?per_page=100")
      runs = Array(payload["check_runs"])
      if runs.empty?
        out.puts "fail: PR ##{pr_number} 没有任何 CI 检查记录，无法确认全绿"
        return :failed
      end

      pending = runs.reject { |run| run["status"].to_s == "completed" }
      unless pending.empty?
        out.puts "fail: PR ##{pr_number} 仍有未完成的检查：#{pending.map { |r| r["name"] }.join("、")}"
        return :failed
      end

      bad = runs.reject { |run| SUCCESSFUL_CONCLUSIONS.include?(run["conclusion"].to_s) }
      unless bad.empty?
        out.puts "fail: PR ##{pr_number} 存在失败的检查：#{bad.map { |r| r["name"] }.join("、")}"
        return :failed
      end

      "#{pr["html_url"]}/checks"
    rescue StandardError => e
      out.puts "fail: 查询 PR ##{pr_number} 的检查记录失败（#{e.message}）"
      :failed
    end

    # 合并后升级：把既有合并前块改写为合并后证据。
    # 先改评论再改正文：评论失败时正文仍是 false，两者一致（都是合并前）。
    def upgrade_after_merge(repo:, issue:, issue_number:, pr_number:, merge_commit:, checks_url:, out:)
      body = issue["body"].to_s
      block = EvidenceRegister.parse_block(body)
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

      # untested 保持登记期的冻结值：重新读卡面会让「合并前已冻结的清单」在升级时漂移。
      upgraded = block.merge(
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
  end
end
