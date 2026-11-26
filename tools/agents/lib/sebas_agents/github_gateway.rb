# frozen_string_literal: true

require "json"

module SebasAgents
  # 从 gh CLI 构造 GitHub 事实源快照。
  # 读路径无副作用；写路径仅限标签（认领/暂停），且每步都回读确认。
  # 网络调用做了缓存与批量补齐，避免逐 issue 往返。
  class GithubGateway
    PAGE_SIZE = 100
    MAX_PAGES = 100
    MAX_DEPENDENCY_FETCH = 300

    ALL_PULL_REQUESTS_QUERY = <<-'GRAPHQL'
      query($owner: String!, $name: String!, $cursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequests(states: [OPEN, CLOSED, MERGED], orderBy: {field: CREATED_AT, direction: DESC}, first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              number
              state
              headRefName
              baseRefName
              headRefOid
              mergeStateStatus
              url
              isCrossRepository
              closingIssuesReferences(first: 10) { pageInfo { hasNextPage } nodes { number } }
              statusCheckRollup { contexts(first: 100) {
                pageInfo { hasNextPage }
                nodes { __typename ... on CheckRun { name status conclusion } ... on StatusContext { context state } }
              } }
            }
          }
        }
      }
    GRAPHQL

    def initialize(runner, repo:)
      @runner = runner
      @repo = repo
      @issue_cache = {}
      @blocked_cache = {}
      @thread_cache = {}
      @author_cache = {}
      @body_cache = {}
    end

    # 认领/暂停所需的写操作：只碰标签，不碰 issue 内容。
    def add_label(number, label, allow_write: false)
      call = ["gh", "issue", "edit", number.to_s, "--repo", @repo, "--add-label", label]
      allow_write ? @runner.with_write(:add_label) { @runner.run!(*call) } : @runner.run!(*call)
    end

    def remove_label(number, label, allow_write: false)
      call = ["gh", "issue", "edit", number.to_s, "--repo", @repo, "--remove-label", label]
      allow_write ? @runner.with_write(:remove_label) { @runner.run!(*call) } : @runner.run!(*call)
    end

# Proposal 索引需要全部评论与置顶状态：分页取全，避免长讨论被截断。
def issue_comments(number)
  paginate("repos/#{@repo}/issues/#{number}/comments")
end

def pinned_comment(number)
  raw = @runner.json!("gh", "api", "repos/#{@repo}/issues/#{number}")
  raw["pinned_comment"]
end

# 置顶走 GraphQL：gh 2.x CLI 没有 pin 子命令，且入参是评论 node_id。
def pin_comment(comment_node_id, allow_write: false)
  query = "mutation { pinIssueComment(input:{issueCommentId:\"#{comment_node_id}\"}) { clientMutationId } }"
  call = ["gh", "api", "graphql", "-f", "query=#{query}"]
  allow_write ? @runner.with_write(:pin_comment) { @runner.run!(*call) } : @runner.run!(*call)
end

def create_comment(number, body, allow_write: false)
  call = ["gh", "api", "repos/#{@repo}/issues/#{number}/comments", "-f", "body=#{body}"]
  allow_write ? @runner.with_write(:create_comment) { @runner.run!(*call) } : @runner.run!(*call)
end

def update_comment(comment_id, body, allow_write: false)
  call = ["gh", "api", "-X", "PATCH", "repos/#{@repo}/issues/comments/#{comment_id}", "-f", "body=#{body}"]
  allow_write ? @runner.with_write(:update_comment) { @runner.run!(*call) } : @runner.run!(*call)
end

    # 回读确认：标签写入不是分布式事务，必须核对远端实际状态。
    def label_present?(number, label)
      raw = @runner.json!("gh", "api", "repos/#{@repo}/issues/#{number}")
      Array(raw["labels"]).any? { |item| item["name"] == label }
    end

    # 状态与类型同样要回读：它们决定选卡与流程分派，不能只信写入返回。
    def set_status(number, status, allow_write: false)
      call = ["gh", "api", "-X", "PATCH", "repos/#{@repo}/issues/#{number}", "-f", "status=#{status}"]
      allow_write ? @runner.with_write(:set_status) { @runner.run!(*call) } : @runner.run!(*call)
    end

    def status_of(number)
      raw = @runner.json!("gh", "api", "repos/#{@repo}/issues/#{number}")
      raw.dig("status", "name")
    end

    def status?(number, name)
      status_of(number).to_s.casecmp?(name)
    end

    def set_type(number, type, allow_write: false)
      call = ["gh", "api", "-X", "PATCH", "repos/#{@repo}/issues/#{number}", "-f", "type=#{type}"]
      allow_write ? @runner.with_write(:set_type) { @runner.run!(*call) } : @runner.run!(*call)
    end

    def type_of(number)
      raw = @runner.json!("gh", "api", "repos/#{@repo}/issues/#{number}")
      raw.dig("type", "name")
    end

    # 回读确认：标签写入不是分布式事务，必须核对远端实际状态。
    def label_present?(number, label)
      raw = @runner.json!("gh", "api", "repos/#{@repo}/issues/#{number}")
      Array(raw["labels"]).any? { |item| item["name"] == label }
    end

    # 状态与类型同样要回读：它们决定选卡与流程分派，不能只信写入返回。
    def set_status(number, status, allow_write: false)
      call = ["gh", "api", "-X", "PATCH", "repos/#{@repo}/issues/#{number}", "-f", "status=#{status}"]
      allow_write ? @runner.with_write(:set_status) { @runner.run!(*call) } : @runner.run!(*call)
    end

    def status_of(number)
      raw = @runner.json!("gh", "api", "repos/#{@repo}/issues/#{number}")
      raw.dig("status", "name")
    end

    def status?(number, name)
      status_of(number).to_s.casecmp?(name)
    end

    def set_type(number, type, allow_write: false)
      call = ["gh", "api", "-X", "PATCH", "repos/#{@repo}/issues/#{number}", "-f", "type=#{type}"]
      allow_write ? @runner.with_write(:set_type) { @runner.run!(*call) } : @runner.run!(*call)
    end

    def type_of(number)
      raw = @runner.json!("gh", "api", "repos/#{@repo}/issues/#{number}")
      raw.dig("type", "name")
    end

    def snapshot(gate_records: {}, external_records: {}, proposal_issue: nil)
      milestones = fetch_milestones
      issues = fetch_all_issues
      pull_requests = fetch_pull_requests(proposal_evidence: !proposal_issue.nil?)
      issues = attach_blocked_by(issues)
      issues = close_over_dependencies(issues)

      blocks = issues.filter_map { |issue| JsonBlock.one(issue.body, "evidence", subject: "issue ##{issue.number}") }
      discovered = discover_records(blocks)
      proposal_evidence = proposal_issue ? proposal_decision_evidence(issues, proposal_issue) : empty_proposal_evidence
      Model::Snapshot.new(
        repo: @repo,
        main_sha: main_sha,
        milestones: milestones,
        issues: issues,
        pull_requests: pull_requests,
        maintainers: maintainers,
        source_authors: resolve_authors(blocks),
        gates: discovered["gates"].merge(gate_records),
        externals: discovered["externals"].merge(external_records),
        trusted_bots: trusted_bots,
        source_bodies: resolve_bodies(blocks),
        proposal_evidence: proposal_evidence
      )
    end

    # 只查一个 issue 的完整信息（含 blocked_by）。用于依赖闭包。
    def fetch_issue(number)
      @issue_cache[number] ||= begin
        raw = @runner.json!("gh", "api", "repos/#{@repo}/issues/#{number}")
        build_issue(raw)
      end
    end

    def fetch_blocked_by(number)
      @blocked_cache[number] ||= begin
        raw = @runner.json!("gh", "api", "repos/#{@repo}/issues/#{number}/dependencies/blocked_by")
        Array(raw).map { |item| item.fetch("number") }
      end
    end

    def fetch_sub_issues(number)
      raw = @runner.json!("gh", "api", "repos/#{@repo}/issues/#{number}/sub_issues")
      Array(raw).map { |item| item.fetch("number") }
    end

    def main_sha
      @main_sha ||= @runner.json!("gh", "api", "repos/#{@repo}/commits/main").fetch("sha")
    end

    def fetch_milestones
      paginate("repos/#{@repo}/milestones?state=all").map do |item|
        Model::Milestone.from_hash(
          "number" => item["number"],
          "title" => item["title"],
          "state" => item["state"],
          "description" => item["description"],
          "open_issues" => item["open_issues"]
        )
      end
    end

    def fetch_all_issues
      paginate("repos/#{@repo}/issues?state=all").reject { |item| item.key?("pull_request") }.map { |raw| build_issue(raw) }
    end

    def fetch_open_issues
      paginate("repos/#{@repo}/issues?state=open").reject { |item| item.key?("pull_request") }.map { |raw| build_issue(raw) }
    end

    # gate:/external: 登记既可在 issue body，也可在 risks.md 等登记表；此处从 issues 内抽取。
    def discover_records(blocks)
      gates = {}
      externals = {}
      blocks.each do |block|
        subject = block["subject"].to_s
        if subject.start_with?("gate:")
          gates[subject] = block
        elsif subject.start_with?("external:")
          externals[subject] = block
        end
      end
      {"gates" => gates, "externals" => externals}
    end

    # 沿 Automation.depends_on 数字引用补齐 closed 前置。
    def close_over_dependencies(issues)
      known = issues.to_h { |issue| [issue.number, issue] }
      queue = issues.dup
      fetched = 0
      until queue.empty?
        issue = queue.shift
        block = JsonBlock.one(issue.body, "automation", subject: "issue ##{issue.number}")
        next unless block

        Array(block["depends_on"]).map(&:to_s).grep(/\A\d+\z/).map(&:to_i).each do |number|
          next if known.key?(number)

          fetched += 1
          if fetched > MAX_DEPENDENCY_FETCH
            raise CommandError.new("依赖闭包超过 #{MAX_DEPENDENCY_FETCH} 张卡，疑似数据异常", command: ["gh", "api"])
          end
          built = fetch_issue(number)
          known[number] = built
          queue << built
        end
      end
      known.values.sort_by(&:number)
    end

    # Proposal 用 HTML 注释登记已读到的裁决 URL，避免模型只给 URL 而快照未取作者与正文。
    def proposal_decision_refs(body)
      body.scan(/^<!-- proposal-decision: (https:\/\/\S+) -->$/).flatten
    end

    # 只解析当前目标 Proposal；普通 issue 的文本不会触发外部读取或阻断全仓快照。
    def proposal_decision_evidence(issues, number)
      issue = issues.find { |item| item.number == number.to_i }
      return empty_proposal_evidence unless issue&.proposal?

      proposal_decision_refs(issue.body).each_with_object({}) do |ref, evidence|
        match = Triager::DECISION_URL.match(ref)
        next unless match

        repo = match[:repo]
        kind = match[:kind]
        parent = match[:number]
        next unless repo == @repo

        anchor = match[:anchor]
        raw = if anchor&.start_with?("issuecomment")
          fetch_ref("repos/#{@repo}/issues/comments/#{match[:id]}")
        elsif anchor&.start_with?("pullrequestreview")
          fetch_ref("repos/#{@repo}/pulls/#{parent}/reviews/#{match[:id]}")
        else
          fetch_ref("repos/#{@repo}/pulls/comments/#{match[:discussion_id]}")
        end
        next unless raw

        parent_url = if kind == "issues"
          raw["issue_url"]
        elsif anchor&.start_with?("issuecomment")
          issue_url = raw["issue_url"].to_s
          next unless issue_url == "https://api.github.com/repos/#{@repo}/issues/#{parent}"
          "https://api.github.com/repos/#{@repo}/pulls/#{parent}"
        else
          raw["pull_request_url"]
        end
        evidence[ref] = {"author" => raw.dig("user", "login"), "body" => raw["body"].to_s, "parent" => parent_url}
      end
    end

    def empty_proposal_evidence
      {}
    end

    def fetch_ref(path)
      @runner.json!("gh", "api", path)
    rescue CommandError
      nil
    end

    def resolve_authors(blocks)
      blocks.each_with_object({}) do |block, memo|
        ref = block["source_ref"].to_s
        next if ref.empty? || memo.key?(ref)

        memo[ref] = ref_author(ref)
      end
    end

    # 被引用评论的正文。用于把授权绑定到「登记内容」而不只是「评论作者」：
    # 只证明 bot/maintainer 写过某条评论，不能证明该评论登记了当前结论。
    def resolve_bodies(blocks)
      blocks.each_with_object({}) do |block, memo|
        ref = block["source_ref"].to_s
        next if ref.empty? || memo.key?(ref)

        memo[ref] = ref_body(ref)
      end
    end

    def ref_body(ref)
      @body_cache[ref] ||= begin
        if (match = ref.match(%r{/issues/(\d+)#issuecomment-(\d+)})) ||
            (match = ref.match(%r{/pull/(\d+)#issuecomment-(\d+)}))
          fetch_body("repos/#{@repo}/issues/comments/#{match[2]}")
        elsif (match = ref.match(%r{/pull/(\d+)#discussion_r(\d+)}))
          fetch_body("repos/#{@repo}/pulls/comments/#{match[2]}")
        elsif (match = ref.match(%r{/pull/(\d+)#pullrequestreview-(\d+)}))
          fetch_body("repos/#{@repo}/pulls/#{match[1]}/reviews/#{match[2]}")
        else
          raise CommandError.new("无法识别的 source_ref：#{ref}", command: ["gh", "api"])
        end
      end
    end

    def ref_author(ref)
      @author_cache[ref] ||= begin
        if (match = ref.match(%r{/issues/(\d+)#issuecomment-(\d+)})) ||
            (match = ref.match(%r{/pull/(\d+)#issuecomment-(\d+)}))
          fetch_login("repos/#{@repo}/issues/comments/#{match[2]}")
        elsif (match = ref.match(%r{/pull/(\d+)#discussion_r(\d+)}))
          fetch_login("repos/#{@repo}/pulls/comments/#{match[2]}")
        elsif (match = ref.match(%r{/pull/(\d+)#pullrequestreview-(\d+)}))
          fetch_login("repos/#{@repo}/pulls/#{match[1]}/reviews/#{match[2]}")
        else
          raise CommandError.new("无法识别的 source_ref：#{ref}", command: ["gh", "api"])
        end
      end
    end

    private

    def fetch_login(path)
      @runner.json!("gh", "api", path).dig("user", "login")
    end

    def fetch_body(path)
      raw = @runner.json!("gh", "api", path)
      raw["body"].to_s
    end

    def attach_blocked_by(issues)
      issues.map do |issue|
        next issue unless JsonBlock.present?(issue.body, "automation")

        issue.with(blocked_by: fetch_blocked_by(issue.number))
      end
    rescue CommandError => e
      raise CommandError.new("读取 blocked_by 失败；不把错误当成空依赖：#{e.message}",
        command: e.command, stderr: e.stderr)
    end

    def build_issue(raw)
      body = raw["body"].to_s
      Model::Issue.from_hash(
        "number" => raw.fetch("number"),
        "title" => raw["title"],
        "state" => raw["state"],
        "state_reason" => raw["state_reason"],
        "body" => body,
        "labels" => Array(raw["labels"]).map { |label| label["name"] },
        "milestone" => raw.dig("milestone", "number"),
        "assignees" => Array(raw["assignees"]).map { |item| item["login"] },
        "blocked_by" => [],
        # Automation 必须在此解析：选卡策略读 issue.automation，
        # 若只留着原始 body，所有工作包都会被判成"缺元数据"。
        "automation" => parse_automation(body, raw.fetch("number")),
        "url" => raw["html_url"],
        # type/status 由 REST issues 接口直接返回对象；missing 时保持 nil。
        "type" => raw["type"],
        "status" => raw["status"]
      )
    end

    def parse_automation(body, number)
      JsonBlock.one(body, "automation", subject: "issue ##{number}")
    rescue InvalidPlan
      # 解析失败留给 Dependencies.automation_for 报出具体原因，
      # 这里不静默伪装成"有元数据"。
      nil
    end

    # PR 全量清单走 GraphQL 分页（M4x-Comm-WP3 #244 后实证）：gh pr list --limit 100
    # 在仓库 PR 总量破百后永远打满单页，原「达到上限即 fail-closed」守卫把
    # verify merge / unclaim / next 全部堵死。游标分页保证全量，无截断面。
    # statusCheckRollup 的 contexts 取 first:100——本仓单 PR 检查数远小于该值。
    def fetch_pull_requests(proposal_evidence: false)
      owner, name = @repo.split("/", 2)
      raw = []
      cursor = nil
      pages = 0
      loop do
        pages += 1
        if pages > MAX_PAGES
          raise CommandError.new("pullRequests 分页超过 #{MAX_PAGES} 页仍未到底，拒绝继续", command: ["gh", "api", "graphql"])
        end
        args = ["gh", "api", "graphql", "-f", "query=#{ALL_PULL_REQUESTS_QUERY}",
          "-f", "owner=#{owner}", "-f", "name=#{name}"]
        args += ["-f", "cursor=#{cursor}"] if cursor
        payload = @runner.json!(*args)
        errors = payload["errors"]
        unless errors.nil? || (errors.respond_to?(:empty?) && errors.empty?)
          raise CommandError.new("pullRequests 查询失败：#{errors.inspect}", command: args)
        end
        conn = payload.dig("data", "repository", "pullRequests")
        raise CommandError.new("pullRequests 查询缺 data.repository.pullRequests", command: args) if conn.nil?
        # 分页元数据强校验（#246 review）：pageInfo 缺失不能静默当末页——
        # 多页清单会被误当成完整快照。只有明确 false 才是合法末页。
        page_info = conn["pageInfo"]
        unless page_info.is_a?(Hash) && (page_info["hasNextPage"] == true || page_info["hasNextPage"] == false)
          raise CommandError.new(
            "pullRequests 分页元数据缺失或非法（pageInfo.hasNextPage 必须为布尔）：#{page_info.inspect[0, 120]}",
            command: args
          )
        end
        nodes = conn["nodes"]
        raise CommandError.new("pullRequests 分页缺 nodes：#{conn.inspect[0, 120]}", command: args) unless nodes.is_a?(Array)
        nodes.each do |node|
          cross = node["isCrossRepository"]
          unless cross == true || cross == false
            raise CommandError.new(
              "pullRequests 节点缺 isCrossRepository 或非布尔（number=#{node["number"]}）：#{cross.inspect}",
              command: args
            )
          end
          # fork PR 先剔除再查内层完整性（#246 review round 3）：fork 的异常数据
          # （如 >10 关联 issue）不得阻断整个快照——排除判断先于内层校验。
          next if cross
          raw << graphql_pr_to_list_item(node)
        end
        break unless page_info["hasNextPage"]
        # 游标推进校验（#246 review）：hasNextPage=true 但 endCursor 空/重复时，
        # 下一次请求会重读同页无限追加 raw——拒绝继续而不是烧配额。
        next_cursor = page_info["endCursor"].to_s
        if next_cursor.empty? || next_cursor == cursor
          raise CommandError.new("pullRequests 分页游标未推进（endCursor 空/重复），拒绝循环重读", command: args)
        end
        cursor = next_cursor
      end
      raw.reject { |item| item["isCrossRepository"] }.map do |item|
        # 只有 open PR 需要未解决 thread；已合并/关闭的 PR 不发起 GraphQL 往返。
        threads = item["state"].to_s.casecmp?("OPEN") ? fetch_review_threads(item["number"]) : []
        # #125：open PR 需要变更文件与正文承载路径联动/安全/CWE 检查；
        # 已合并/关闭 PR 的快照不带这两项（检查不可判定即留痕 unverified）。
        # 详情必须属于快照记录的同一 head：两次请求间若 PR 推了新提交，
        # 门禁会拿旧 head 的 checks 配新 head 的 files 形成混合快照——fail-closed。
        details = if proposal_evidence
          # 提案研判只需要设计 PR 正文回链，不需要变更文件或 head 混合快照。
          {"body" => read_pr_detail(item["number"])["body"].to_s}
        elsif item["state"].to_s.casecmp?("OPEN")
          fetch_pr_details(item["number"], expected_head: item["headRefOid"])
        else
          {}
        end
        Model::PullRequest.from_hash(
          "number" => item["number"],
          "head_ref_name" => item["headRefName"],
          "base_ref_name" => item["baseRefName"],
          "head_sha" => item["headRefOid"],
          "state" => item["state"],
          "merge_state_status" => item["mergeStateStatus"],
          "checks" => normalize_checks(item["statusCheckRollup"]),
          "review_threads" => threads,
          "closing_issues" => Array(item["closingIssuesReferences"]).map { |ref| ref["number"] },
          "url" => item["url"]
        ).merge_pr_details(details)
      end
    end

    # GraphQL 节点映射回 gh pr list 的 item 形状，下游转换零改动：
    # - closingIssuesReferences 取 nodes 数组（gh pr list 输出即数组）；
    # - statusCheckRollup 取 contexts.nodes（normalize_checks 已兼容 StatusContext 的
    #   只有 state 无 status 的形状，不能凭空补 COMPLETED）；
    # - 内层连接强校验（#246 review round 2/3/4）：连接字段缺失即拒绝（closing
    #   关联丢失会让 selection 重复分配）；仅 statusCheckRollup 显式 null 合法
    #   （检查未产出）；存在的连接必须有对象 pageInfo、严格布尔 hasNextPage、
    #   数组 nodes，超 first 上限截断即拒绝。
    # - isCrossRepository 的布尔校验与 fork 剔除在调用方完成（先排除后查内层）。
    def graphql_pr_to_list_item(node)
      inner_nodes = lambda { |path, limit|
        conn = node.dig(*path)
        raise CommandError.new(
          "PR ##{node["number"]} 缺 #{path.first} 连接字段（结构非法，不得当空集放行）",
          command: ["gh", "api", "graphql"]
        ) if conn.nil?
        page_info = conn["pageInfo"]
        unless page_info.is_a?(Hash) && (page_info["hasNextPage"] == true || page_info["hasNextPage"] == false)
          raise CommandError.new(
            "PR ##{node["number"]} 的 #{path.join(".")} 分页元数据缺失或非法：#{page_info.inspect[0, 120]}",
            command: ["gh", "api", "graphql"]
          )
        end
        ns = conn["nodes"]
        raise CommandError.new(
          "PR ##{node["number"]} 的 #{path.join(".")} 缺 nodes",
          command: ["gh", "api", "graphql"]
        ) unless ns.is_a?(Array)
        if page_info["hasNextPage"]
          raise CommandError.new(
            "PR ##{node["number"]} 的 #{path.join(".")} 超过 #{limit} 条被截断，拒绝产出不完整快照",
            command: ["gh", "api", "graphql"]
          )
        end
        ns
      }
      # statusCheckRollup 显式 null = 检查未产出（合法空集）；字段缺失 = 结构非法
      rollup_nodes = if node.key?("statusCheckRollup") && node["statusCheckRollup"].nil?
        []
      else
        inner_nodes.call(["statusCheckRollup", "contexts"], 100)
      end
      closing_nodes = inner_nodes.call(["closingIssuesReferences"], 10)
      {
        "number" => node["number"],
        "headRefName" => node["headRefName"],
        "baseRefName" => node["baseRefName"],
        "headRefOid" => node["headRefOid"],
        "state" => node["state"],
        "mergeStateStatus" => node["mergeStateStatus"],
        "statusCheckRollup" => rollup_nodes,
        "closingIssuesReferences" => closing_nodes.map { |n| { "number" => n["number"] } },
        "url" => node["url"],
        "isCrossRepository" => false
      }
    end

    # PR 详情：正文 + 变更文件（filename/patch）。失败必须抛错——
    # 缺数据时 verify_merge 会留痕 unverified，但拿不到详情这个事实本身
    # 不允许被静默吞掉。
    # expected_head：快照记录的 head sha。详情取回后回读当前 head，
    # 不一致直接抛错（fail-closed）——不能把旧 head 的 checks 配新 head 的
    # files 拼成混合快照让门禁误判（CodeRabbit）。
    def fetch_pr_details(number, expected_head: nil)
      pr = read_pr_detail(number)
      ensure_head_unchanged!(number, pr, expected_head)
      files = @runner.json!("gh", "api", "repos/#{@repo}/pulls/#{number}/files?per_page=100")
      # files 请求期间若 PR 推进了 head，取到的 files 已属于新 head——
      # 必须再次比对（CodeRabbit：两次请求夹缝同样会形成混合快照）。
      ensure_head_unchanged!(number, read_pr_detail(number), expected_head)
      unless files.is_a?(Array)
        raise CommandError.new("PR ##{number} files 返回非数组", command: ["gh", "api", "pulls/#{number}/files"])
      end
      if files.length >= 100
        raise CommandError.new(
          "PR ##{number} 变更文件达到单页上限 100，可能截断；路径联动检查需要全量文件",
          command: ["gh", "api", "pulls/#{number}/files"]
        )
      end
      {"body" => pr.is_a?(Hash) ? pr["body"].to_s : "", "files" => files}
    end

    private

    def read_pr_detail(number)
      @runner.json!("gh", "api", "repos/#{@repo}/pulls/#{number}",
        "--jq", "{body: .body, head_sha: .head.sha}")
    end

    def ensure_head_unchanged!(number, pr, expected_head)
      unless expected_head && pr.is_a?(Hash)
        # 快照身份未经确认不得放行（CodeRabbit）：缺 head 或结构非法一律拒绝。
        raise CommandError.new(
          "PR ##{number} 详情结构非法或快照缺 head sha（expected=#{expected_head.inspect}）；" \
          "拒绝构建快照（fail-closed）",
          command: ["gh", "api", "pulls/#{number}"]
        )
      end
      return if pr["head_sha"].to_s == expected_head.to_s

      raise CommandError.new(
        "PR ##{number} 在采集期间推进了 head（快照=#{expected_head}，当前=#{pr["head_sha"]}）；" \
        "拒绝构建混合快照，请重跑选择器",
        command: ["gh", "api", "pulls/#{number}"]
      )
    end

    # reviewThreads 连接没有 isResolved 查询参数：取回后在本地过滤。
    # GraphQL 出错（errors 非空、data/pullRequest 为 null）必须报错，
    # 绝不能当成「没有未解决 thread」——那是合并门禁上的 fail-open。
    def fetch_review_threads(number)
      @thread_cache[number] ||= begin
        owner, name = @repo.split("/", 2)
        threads = []
        cursor = nil
        loop do
          args = ["gh", "api", "graphql", "-f", "query=#{REVIEW_THREADS_QUERY}",
            "-f", "owner=#{owner}", "-f", "name=#{name}", "-F", "number=#{number}"]
          args += ["-f", "cursor=#{cursor}"] if cursor
          payload = @runner.json!(*args)
          errors = payload["errors"]
          unless errors.nil? || (errors.respond_to?(:empty?) && errors.empty?)
            raise CommandError.new("reviewThreads 查询失败：#{errors.inspect}", command: args)
          end
          connection = payload.dig("data", "repository", "pullRequest", "reviewThreads")
          unless connection.is_a?(Hash)
            raise CommandError.new("reviewThreads 响应缺数据（PR ##{number}），拒绝判定为无 thread", command: args)
          end

          threads.concat(Array(connection["nodes"]))
          break unless connection.dig("pageInfo", "hasNextPage")

          cursor = connection.dig("pageInfo", "endCursor")
          raise CommandError.new("reviewThreads 分页缺 cursor", command: args) if cursor.nil? || cursor.empty?
        end
        threads
      end
    end

    REVIEW_THREADS_QUERY = <<~GRAPHQL
      query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            reviewThreads(first: 100, after: $cursor) {
              nodes { isResolved }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      }
    GRAPHQL

    def normalize_checks(rollup)
      Array(rollup).map do |check|
        # StatusContext（旧式）只有 state，没有 status；不能凭空补成 COMPLETED。
        status = check["status"] || status_from_state(check["state"])
        {
          "name" => check["name"] || check["context"],
          "status" => status,
          "conclusion" => (check["conclusion"] || check["state"]).to_s
        }
      end
    end

    # StatusContext.state：EXPECTED/PENDING 未完成，其余视为已完成。
    def status_from_state(state)
      case state.to_s.upcase
      when "EXPECTED", "PENDING", "QUEUED", "IN_PROGRESS" then "IN_PROGRESS"
      when "" then "UNKNOWN"
      else "COMPLETED"
      end
    end

    def maintainers
      @maintainers ||= begin
        path = File.join(Dir.pwd, ".github", "agents.yml")
        unless File.exist?(path)
          raise CommandError.new(
            "缺少 .github/agents.yml（maintainers 名单）；无法校验证据登记人，按 fail-closed 处理",
            command: ["read", path]
          )
        end

        require "yaml"
        data = YAML.safe_load_file(path)
        list = Array(data && data["maintainers"]).map(&:to_s).reject(&:empty?)
        raise CommandError.new(".github/agents.yml 的 maintainers 为空", command: ["read", path]) if list.empty?

        list
      end
    end

    # 授权可代写 Evidence 的自动化身份（如 "github-actions[bot]"）。
    # 缺省为空：未显式授权时 workflow 登记一律 invalid，仍是 fail-closed。
    def trusted_bots
      @trusted_bots ||= begin
        path = File.join(Dir.pwd, ".github", "agents.yml")
        return [] unless File.exist?(path)

        require "yaml"
        data = YAML.safe_load_file(path)
        Array(data && data["trusted_bots"]).map(&:to_s).reject(&:empty?)
      end
    end

    def paginate(path)
      separator = path.include?("?") ? "&" : "?"
      items = []
      page = 1
      loop do
        batch = @runner.json!("gh", "api", "#{path}#{separator}per_page=#{PAGE_SIZE}&page=#{page}")
        # 非数组说明 API 返回了错误体；绝不能当成空列表（那样会得出 idle）。
        unless batch.is_a?(Array)
          raise CommandError.new("分页接口返回非数组：#{path} → #{batch.inspect[0, 200]}",
            command: ["gh", "api", path])
        end

        items.concat(batch)
        break if batch.length < PAGE_SIZE

        page += 1
        raise CommandError.new("分页超过 #{MAX_PAGES} 页：#{path}", command: ["gh", "api", path]) if page > MAX_PAGES
      end
      items
    end
  end
end
