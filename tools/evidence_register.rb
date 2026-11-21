# frozen_string_literal: true

# Evidence 自动登记（#113）。
#
# PR 合并、关联 issue completed、CI 全绿之后，以 github-actions[bot] 身份
# 登记一条 Evidence 评论并回填 issue 正文的 Evidence 小节。
#
# 设计原则：
#   1. fail-closed：任一前置不满足就跳过，且**不留半截状态**。
#      评论发出后若后续步骤失败，必须删除该评论再退出。
#   2. 幂等：已有有效 Evidence 直接跳过，不重复发评论。
#   3. 不编造未实测项：CI 覆盖不到的验收必须由判定写入 untested，
#      宁可阻塞也不写 []。
#   4. source_ref 必须指回刚发布的评论，否则 registration_matches? 判未授权。

require "json"
require "open3"

module EvidenceRegister
  EVIDENCE_FENCE = "json evidence"
  BOT_MARKER = "<!-- evidence-register:bot -->"

  # 测试注入点。生产环境为 nil，走真实 gh CLI。
  class << self
    attr_accessor :runner
  end

  # 该期门禁要求但 CI 覆盖不到的验收项。命中则写入 untested 而不是假装已测。
  # 目前为空：本仓 CI 已覆盖 spec×3 / ameba / docs / format。
  # 新增真机验证类要求时在此登记，例：["M7 真机 round-trip"]。
  UNTESTED_REQUIREMENTS = [].freeze

  module_function

  def run(env: ENV, out: $stdout)
    pr_number = resolve_pr(env)
    if pr_number.nil?
      out.puts "skip: 无法确定 PR 编号"
      return 0
    end

    repo = env.fetch("GITHUB_REPOSITORY")
    pr = gh_json("repos/#{repo}/pulls/#{pr_number}")

    unless pr["merged_at"]
      out.puts "skip: PR ##{pr_number} 未合并（merged_at 为空）"
      return 0
    end

    issue_number = closing_issue(pr)
    if issue_number.nil?
      out.puts "skip: PR ##{pr_number} 未通过 Fixes #n 关联唯一 issue"
      return 0
    end

    issue = gh_json("repos/#{repo}/issues/#{issue_number}")
    unless issue["state"] == "closed" && issue["state_reason"] == "completed"
      out.puts "skip: issue ##{issue_number} 不是 completed（#{issue["state"]}/#{issue["state_reason"]}）"
      return 0
    end

    if existing_evidence(issue["body"])
      out.puts "skip: issue ##{issue_number} 已有 Evidence 块（幂等）"
      return 0
    end

    # 发布评论：以 workflow 的 GITHUB_TOKEN 身份，即 github-actions[bot]。
    # 先用占位正文发，拿到 URL 后再 PATCH 成含真 source_ref 的版本；
    # 任何后续步骤失败都必须删掉这条评论，否则会留下孤儿评论
    # （下次运行虽会因「无 Evidence 块」重跑，但 issue 上会堆出多条空评论）。
    comment_body = render_comment_placeholder(issue_number)
    comment = gh_json("repos/#{repo}/issues/#{issue_number}/comments",
      method: "POST", body: {"body" => comment_body})
    comment_url = comment["html_url"]
    out.puts "posted comment: #{comment_url}"

    begin
      # 用真实评论 URL 重写正文（source_ref 必须指回它）。
      block = evidence_block(
        issue_number: issue_number,
        pr_number: pr_number,
        merge_commit: pr["merge_commit_sha"],
        checks: env["RUN_URL"],
        untested: UNTESTED_REQUIREMENTS,
        source_ref: comment_url
      )
      gh_json("repos/#{repo}/issues/comments/#{comment["id"]}",
        method: "PATCH", body: {"body" => render_comment(block)})

      # 回填 issue 正文的 Evidence 小节。
      updated = upsert_evidence_section(issue["body"], block)
      gh_json("repos/#{repo}/issues/#{issue_number}",
        method: "PATCH", body: {"body" => updated})
    rescue StandardError
      # 回滚：删掉刚发的评论，恢复「无任何写入」的状态。
      begin
        gh_json("repos/#{repo}/issues/comments/#{comment["id"]}", method: "DELETE")
        out.puts "rollback: 已删除评论 #{comment["id"]}"
      rescue StandardError => cleanup_error
        warn "::error::回滚失败，issue ##{issue_number} 残留评论 #{comment_url}（#{cleanup_error.message}）"
      end
      raise
    end

    out.puts "issue ##{issue_number} Evidence 已登记"
    0
  rescue StandardError => e
    warn "::error::Evidence 登记失败：#{e.class}: #{e.message}"
    1
  end

  def resolve_pr(env)
    if env["EVENT_NAME"] == "workflow_dispatch"
      value = env["INPUT_PR"].to_s
      return nil if value.strip.empty?

      Integer(value, 10)
    else
      value = env["RUN_PR"].to_s
      return nil if value.strip.empty? || value == "null"

      Integer(value, 10)
    end
  rescue ArgumentError
    nil
  end

  # 从 PR 正文的 Fixes/Closes #n 取唯一关联 issue。
  def closing_issue(pr)
    body = pr["body"].to_s
    numbers = body.scan(/\b(?:fix(?:es|ed)?|close[sd]?|resolve[sd]?)\s+#(\d+)/i).flatten.map(&:to_i).uniq
    numbers.length == 1 ? numbers.first : nil
  end

  def existing_evidence(body)
    text = body.to_s
    return nil unless text.include?(EVIDENCE_FENCE)

    match = text.match(/```json evidence\s*(\{.*?\})\s*```/m)
    return nil unless match

    JSON.parse(match[1])
  rescue JSON::ParserError
    nil
  end

  def evidence_block(issue_number:, pr_number:, merge_commit:, checks:, untested:, source_ref:)
    {
      "schema" => 1,
      "subject" => "issue:#{issue_number}",
      "status" => "accepted",
      "source" => "workflow",
      "source_ref" => source_ref,
      "pr" => pr_number,
      "merge_commit" => merge_commit,
      "merged_into_main" => true,
      "checks" => checks,
      "gate_status" => nil,
      "evidence_path" => nil,
      "untested" => untested,
      "ready" => nil
    }
  end

  # 占位正文：先发评论拿到 URL，再 PATCH 成含真 source_ref 的版本。
  def render_comment_placeholder(issue_number)
    "#{BOT_MARKER}\n\n## Evidence 登记（issue:#{issue_number}）\n\n_生成中…_\n"
  end

  def render_comment(block)
    <<~MD
      #{BOT_MARKER}

      ## Evidence 登记（#{block["subject"]}）

      由 `evidence-register` workflow 在 PR 合并、issue completed 后自动登记。

      ```#{EVIDENCE_FENCE}
      #{JSON.pretty_generate(block)}
      ```
    MD
  end

  # 替换已有的 Evidence 小节；没有则追加。
  def upsert_evidence_section(body, block)
    text = body.to_s.dup
    fence = "```#{EVIDENCE_FENCE}\n#{JSON.pretty_generate(block)}\n```\n"
    section = "## Evidence\n\n#{fence}"

    if text =~ /^##\s+Evidence\s*$/m
      # 已有小节：整体替换到下一个二级标题为止。
      text.sub!(/^##\s+Evidence\s*$.*?(?=^##\s+\S|\z)/m, section)
      text
    else
      "#{text.rstrip}\n\n#{section}"
    end
  end

  # gh 调用统一入口。测试可替换 @runner 注入假实现，避免 monkey-patch 污染。
  def gh_json(path, method: "GET", body: nil)
    return runner.call(path, method: method, body: body) if runner

    args = ["gh", "api", "-X", method, path]
    if body
      args += ["--input", "-"]
      out, err, status = Open3.capture3(*args, stdin_data: JSON.generate(body))
    else
      out, err, status = Open3.capture3(*args)
    end
    raise "gh api #{method} #{path} 失败：#{err.strip}" unless status.success?

    JSON.parse(out)
  end
end

exit(EvidenceRegister.run) if $PROGRAM_NAME == __FILE__
