# frozen_string_literal: true

# Evidence 自动登记（#113）。
#
# PR 合并、关联 issue completed、CI 全绿之后，以 github-actions[bot] 身份
# 登记一条 Evidence 评论并回填 issue 正文的 Evidence 小节。
#
# 设计原则：
#   1. fail-closed：任一前置不满足就跳过，且不留半截状态。
#      仅在确认远端正文未引用该评论时才删除评论，否则保留并报人工修复。
#   2. 幂等：已有**有效** Evidence 直接跳过；无效块显式报错而非假装成功。
#   3. 不编造未实测项：untested 的唯一来源是 issue 正文的「未实测」小节，
#      CI 覆盖不到的验收项必须由人写进卡面，脚本只做搬运。
#   4. source_ref 必须指回刚发布的评论，否则 registration_matches? 判未授权。
#   5. merged_into_main 必须由 git 祖先关系证实，不因 merged_at 存在就置 true。

require "json"
require "open3"

module EvidenceRegister
  EVIDENCE_FENCE = "json evidence"
  BOT_MARKER = "<!-- evidence-register:bot -->"

  # 测试注入点。生产环境为 nil，走真实 gh / git。
  class << self
    attr_accessor :runner, :git_runner
  end

  module_function

  def run(env: ENV, out: $stdout)
    repo = env.fetch("GITHUB_REPOSITORY")

    pr_number = resolve_pr(env)
    if pr_number.nil?
      out.puts "skip: 无法从事件确定 PR 编号"
      return 0
    end

    pr = gh_json("repos/#{repo}/pulls/#{pr_number}")
    unless pr["merged_at"]
      out.puts "skip: PR ##{pr_number} 未合并（merged_at 为空）"
      return 0
    end

    merge_commit = pr["merge_commit_sha"].to_s
    unless merged_into_main?(merge_commit, base_ref: pr["base"] && pr["base"]["ref"], out: out)
      out.puts "skip: merge commit #{merge_commit[0, 8]} 不在 main 上"
      return 0
    end

    checks_url = resolve_checks_url(env, pr_number, out: out)
    return 1 if checks_url == :failed

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

    case existing_evidence(issue["body"], subject: "issue:#{issue_number}")
    when :valid
      out.puts "skip: issue ##{issue_number} 已有有效 Evidence（幂等）"
      return 0
    when :invalid
      warn "::error::issue ##{issue_number} 的现有 Evidence 块结构非法，需人工修复后再登记"
      return 1
    end

    register(repo: repo, issue: issue, issue_number: issue_number, pr_number: pr_number,
      merge_commit: merge_commit, checks_url: checks_url, out: out)
    0
  rescue StandardError => e
    # 顶层兜底：workflow 依靠退出码判定成败，异常不得逃逸成未捕获崩溃。
    warn "::error::Evidence 登记失败：#{e.class}: #{e.message}"
    1
  end

  # --- 登记主流程 ---

  def register(repo:, issue:, issue_number:, pr_number:, merge_commit:, checks_url:, out:)
    untested = declared_untested(issue["body"])
    comment = post_placeholder(repo, issue_number, out)
    comment_url = comment["html_url"]
    comment_id = comment["id"]

    begin
      block = evidence_block(
        issue_number: issue_number,
        pr_number: pr_number,
        merge_commit: merge_commit,
        checks: checks_url,
        untested: untested,
        source_ref: comment_url
      )
      gh_json("repos/#{repo}/issues/comments/#{comment_id}",
        method: "PATCH", body: {"body" => render_comment(block)})

      # 重新读取正文再写入：缩小覆盖并发编辑的窗口。
      fresh = gh_json("repos/#{repo}/issues/#{issue_number}")
      fresh_untested = declared_untested(fresh["body"])
      unless fresh_untested == untested
        # 首读到写入之间有人改了「未实测」小节：此时登记会把新增项漏掉，
        # 且评论与正文块会一致（都缺），下游无从发现。必须中止。
        raise "issue ##{issue_number} 的「未实测」声明在登记期间发生变化：" \
          "#{untested.inspect} → #{fresh_untested.inspect}；请重跑"
      end
      updated = upsert_evidence_section(fresh["body"], block)
      gh_json("repos/#{repo}/issues/#{issue_number}",
        method: "PATCH", body: {"body" => updated})
    rescue StandardError
      reconcile_rollback(repo, issue_number, comment_id, comment_url, out)
      raise
    end

    out.puts "issue ##{issue_number} Evidence 已登记（untested=#{untested.inspect}）"
  end

  # 回滚前先核对：远端正文是否仍引用该评论。
  # 若正文已写入但 PATCH 报错（服务端可能已生效），删评论会留下悬空 source_ref。
  def reconcile_rollback(repo, issue_number, comment_id, comment_url, out)
    body = gh_json("repos/#{repo}/issues/#{issue_number}")["body"].to_s
    if body.include?(comment_url)
      warn "::error::issue ##{issue_number} 已引用评论 #{comment_url}，不删除；需人工核对正文块"
      return
    end

    gh_json("repos/#{repo}/issues/comments/#{comment_id}", method: "DELETE")
    out.puts "rollback: 已删除评论 #{comment_id}"
  rescue StandardError => e
    warn "::error::回滚失败，残留评论 #{comment_url}（#{e.message}）"
  end

  def post_placeholder(repo, issue_number, out)
    comment = gh_json("repos/#{repo}/issues/#{issue_number}/comments",
      method: "POST", body: {"body" => render_comment_placeholder(issue_number)})
    out.puts "posted comment: #{comment["html_url"]}"
    comment
  end

  # --- 事件 → PR ---

  # workflow_run 有两种来源：
  #   pull_request：CI 在 PR 上跑，pull_requests[0] 给出编号（此时 PR 尚未合并）。
  #   push：合并后 main 上的 CI，pull_requests[] 通常为空，
  #         必须用 head_sha 反查「已合并且包含该 commit 的 PR」。
  def resolve_pr(env)
    if env["EVENT_NAME"] == "workflow_dispatch"
      value = env["INPUT_PR"].to_s.strip
      return nil if value.empty?

      number = Integer(value, 10)
      # 归一化：拒绝 099 这类非规范写法，避免并发组不一致导致重复登记。
      return nil unless number.to_s == value

      return number
    end

    if (value = env["RUN_PR"].to_s.strip) != "" && value != "null"
      return Integer(value, 10)
    end

    head_sha = env["RUN_HEAD_SHA"].to_s.strip
    return nil if head_sha.empty?

    pr = pr_for_commit(env.fetch("GITHUB_REPOSITORY"), head_sha)
    pr && pr["number"]
  rescue ArgumentError
    nil
  end

  def pr_for_commit(repo, sha)
    candidates = gh_json("repos/#{repo}/commits/#{sha}/pulls")
    Array(candidates).find { |pr| pr["merged_at"] }
  rescue StandardError
    nil
  end

  # --- CI 证据 ---

  # 手动触发时 RUN_URL 为空，必须自己确认 CI 成功，
  # 否则会写出 checks 为空字符串的 accepted 证据。
  #
  # workflow_run 路径也要校验 user  commit 与 merge_commit 一致：
  # PR head 上的 CI 可能在 PR 合并后才完成，此时它有成功的 run，
  # 但它测的不是合入后的提交，不能拿它的 URL 当合并结果的证据。
  def resolve_checks_url(env, pr_number, out:)
    url = env["RUN_URL"].to_s.strip
    run_sha = env["RUN_HEAD_SHA"].to_s.strip
    request_sha = env["REQUEST_SHA"].to_s.strip

    unless url.empty?
      # 没有触发提交信息时无法做一致性比对，保持原有信任（workflow_run 必然带 head_sha）。
      return url if run_sha.empty?

      repo = env.fetch("GITHUB_REPOSITORY")
      expected = request_sha.empty? ? gh_json("repos/#{repo}/pulls/#{pr_number}")["merge_commit_sha"].to_s : request_sha
      if run_sha != expected
        out.puts "fail: 触发 CI 的 commit #{run_sha[0, 8]} 与 merge commit #{expected[0, 8]} 不一致，拒绝登记"
        return :failed
      end
      return url
    end

    repo = env.fetch("GITHUB_REPOSITORY")
    sha = gh_json("repos/#{repo}/pulls/#{pr_number}")["merge_commit_sha"].to_s
    runs = gh_json("repos/#{repo}/actions/runs?head_sha=#{sha}&per_page=20")
    success = Array(runs["workflow_runs"]).find { |r| r["name"] == "CI" && r["conclusion"] == "success" }
    unless success
      out.puts "fail: PR ##{pr_number} 找不到成功的 CI run，拒绝登记"
      return :failed
    end
    success["html_url"]
  rescue StandardError
    out.puts "fail: 查询 CI run 失败，拒绝登记"
    :failed
  end

  # --- main 祖先校验 ---

  # merged_at 只说明 PR 被合并，不说明合到了 main。
  # 手动触发可以选择合并进 release 分支的 PR，那种提交不能宣称 merged_into_main。
  def merged_into_main?(sha, base_ref: nil, out: $stdout)
    return false if sha.to_s.empty?
    return false if base_ref && base_ref != "main"

    run_git("merge-base", "--is-ancestor", sha, "origin/main")
  rescue StandardError
    out.puts "warn: 无法校验 #{sha[0, 8]} 是否为 main 祖先，按未合入处理"
    false
  end

  def run_git(*args)
    return git_runner.call(*args) if git_runner

    _out, _err, status = Open3.capture3("git", *args)
    status.success?
  end

  # --- 幂等判定 ---

  # :absent / :valid / :invalid
  def existing_evidence(body, subject:)
    text = body.to_s
    # 必须是真正的 ```json evidence 围栏，不能只看正文里是否出现这几个词。
    # 否则「Document the json evidence format.」这类叙述会被当成损坏的块，
    # 导致登记永远失败且重试无效。
    return :absent unless text.match?(/^```json evidence\s*$/m)

    block = parse_block(text)
    # 有 fence 却解析不出来 = 结构损坏，不能当成「没有证据」放行，
    # 否则会追加第二个块，或者把损坏块留在原地。
    return :invalid if block.nil?

    valid = block["schema"] == 1 &&
      block["subject"].to_s == subject &&
      !block["status"].to_s.empty? &&
      !block["source"].to_s.empty? &&
      !block["source_ref"].to_s.empty?
    valid ? :valid : :invalid
  end

  def parse_block(body)
    text = body.to_s
    return nil unless text.include?(EVIDENCE_FENCE)

    match = text.match(/```json evidence\s*(\{.*?\})\s*```/m)
    return nil unless match

    JSON.parse(match[1])
  rescue JSON::ParserError
    nil
  end

  # --- untested 唯一来源 ---

  # 从 issue 正文的「未实测」小节搬运待验证项。
  # 为空表示该卡没有额外要求，交由 CI 覆盖；脚本不自行发明，也不掩盖。
  def declared_untested(body)
    match = body.to_s.match(/^#+\s*未实测\s*$(.*?)(?=^#+\s+\S|\z)/m)
    return [] unless match

    match[1].lines.map { |line| line.sub(/\A[-*]\s*/, "").strip }
      .reject(&:empty?)
      .reject { |line| line.match?(/\A(无|none|n\/a)\z/i) }
  end

  # --- 证据块 ---

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

  def closing_issue(pr)
    body = pr["body"].to_s
    numbers = body.scan(/\b(?:fix(?:es|ed)?|close[sd]?|resolve[sd]?)\s+#(\d+)/i).flatten.map(&:to_i).uniq
    numbers.length == 1 ? numbers.first : nil
  end

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

  # 替换已有的 Evidence 小节；没有则追加。保留其余小节原样。
  def upsert_evidence_section(body, block)
    text = body.to_s.dup
    fence = "```#{EVIDENCE_FENCE}\n#{JSON.pretty_generate(block)}\n```\n"
    section = "## Evidence\n\n#{fence}"

    if text =~ /^##\s+Evidence\s*$/m
      text.sub!(/^##\s+Evidence\s*$.*?(?=^##\s+\S|\z)/m, section)
      text
    else
      "#{text.rstrip}\n\n#{section}"
    end
  end

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
