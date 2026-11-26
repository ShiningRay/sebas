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
    # 原生 blocked_by 单条端点每次约 1.5s（进程 + TLS 握手），逐卡请求是
    # 快照的主要耗时项之一。改 GraphQL 别名批量后，一批只付一次固定成本。
    # 50 是实测的安全批量：82 张卡 2 批共 2.1s，单批 query 远低于长度上限。
    BLOCKED_BY_BATCH = 50
    # blockedBy 连接的节点上限。超过即拒绝——截断会让依赖判定漏看前置。
    BLOCKED_BY_PAGE = 100

    # PR 清单只取身份与关联字段。statusCheckRollup 单独按需取：
    # 它对每个 PR 都要服务端汇总 contexts，实测 106 个 PR 全量取要 4.2~6.2s / 139KB，
    # 而当期 open PR 为 0——绝大多数载荷无人消费。
    # 只有 OPEN 的 PR（选择器与 pre 核验要判 CI）和调用方显式指定的 PR
    # （合并后核验要复核 CI）才值得付这份成本。
    PULL_REQUEST_LIST_QUERY = <<-'GRAPHQL'
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
            }
          }
        }
      }
    GRAPHQL

    # statusCheckRollup 的 contexts 单页上限；超了即拒绝，不产出不完整检查清单。
    ROLLUP_PAGE = 100

    def initialize(runner, repo:)
      @runner = runner
      @repo = repo
      @issue_cache = {}
      @blocked_cache = {}
      @thread_cache = {}
      @author_cache = {}
      @body_cache = {}
      @issue_comment_index = nil
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

    def snapshot(gate_records: {}, external_records: {}, proposal_issue: nil, verified_pr: nil)
      milestones = fetch_milestones
      issues = fetch_all_issues
      pull_requests = fetch_pull_requests(proposal_evidence: !proposal_issue.nil?)
      # verify merge 要复核指定 PR 的 CI：清单已不带 rollup，这里按编号补取。
      # 补不到就抛错——宁可失败，也不能让门禁拿着「未取」当「通过」。
      pull_requests = attach_checks(pull_requests, [verified_pr]) if verified_pr
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

    # 给指定编号的 PR 补取 CI 汇总（verify merge 的目标 PR）。
    # 名单里的 PR 必须在快照内：编号对不上说明快照与请求不匹配，直接拒绝。
    def attach_checks(pull_requests, numbers)
      wanted = numbers.map(&:to_i).uniq
      missing = wanted - pull_requests.map(&:number)
      unless missing.empty?
        raise CommandError.new(
          "PR #{missing.map { |n| "##{n}" }.join("、")} 不在快照内，无法补取 CI 检查",
          command: ["gh", "api", "graphql"]
        )
      end

      # head 必须绑定到快照记录：checks 反映的是 PR 当前 head，
      # 不校验就会把新提交的绿灯安到旧 head 的核验结论上。
      heads = pull_requests.to_h { |pr| [pr.number, pr.head_sha] }
      loaded = wanted.to_h do |number|
        [number, fetch_checks(number, expected_head: heads[number])]
      end
      pull_requests.map do |pr|
        loaded.key?(pr.number) ? pr.with(checks: loaded[pr.number]) : pr
      end
    end

    # 只查一个 issue 的完整信息（含 blocked_by）。依赖闭包按需补取走这里。
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

    # 批量拉取 blocked_by：一次 GraphQL 查询带 BLOCKED_BY_BATCH 个别名。
    # 供 attach_blocked_by 组装快照；单卡读取见 fetch_blocked_by。
    #
    # 四条 fail-closed 校验，缺一都可能把「读不到」当成「没有前置」：
    #   1. 任何别名缺节点（issue 不存在/无权访问）→ 拒绝，不返回部分结果；
    #   2. blockedBy 连接必须是对象且 nodes 是数组 → 拒绝，不当空集；
    #   3. totalCount 必须是非负整数且不超 nodes.length（缺失/nil 经 to_i 会变 0，
    #      把截断读成「无前置」；被 first 截断同样拒绝）；
    #   4. 回读编号与请求不符（别名错位）→ 拒绝，避免依赖张冠李戴。
    def fetch_blocked_by_batch(numbers)
      numbers.each_slice(BLOCKED_BY_BATCH).each_with_object({}) do |group, result|
        fields = group.each_with_index.map do |number, index|
          "b#{index}: issue(number: #{number}) { number blockedBy(first: #{BLOCKED_BY_PAGE}) " \
            "{ totalCount nodes { number } } }"
        end
        owner, name = @repo.split("/", 2)
        args = ["gh", "api", "graphql",
          "-f", "query=#{blocked_by_query(owner, name, fields)}"]
        payload = @runner.json!(*args)
        errors = payload["errors"]
        unless errors.nil? || (errors.respond_to?(:empty?) && errors.empty?)
          raise CommandError.new("blocked_by 批量查询失败：#{errors.inspect}", command: args)
        end
        data = payload.dig("data", "repository")
        unless data.is_a?(Hash)
          raise CommandError.new("blocked_by 批量查询缺 data.repository：#{payload.inspect[0, 160]}",
            command: args)
        end

        group.each_with_index do |number, index|
          node = data["b#{index}"]
          if node.nil?
            raise CommandError.new(
              "blocked_by 批量查询缺 issue ##{number} 节点（不存在或无权访问），" \
              "拒绝产出不完整依赖图", command: args
            )
          end
          connection = node["blockedBy"]
          nodes = connection.is_a?(Hash) ? connection["nodes"] : nil
          unless nodes.is_a?(Array)
            raise CommandError.new("issue ##{number} 的 blockedBy 连接结构非法：#{connection.inspect[0, 120]}",
              command: args)
          end
          total = connection["totalCount"]
          # 显式校验而非 to_i：缺失/nil/字符串都会被静默当成 0，
          # 于是 nodes 为空时看着合法，实际是读坏了。
          unless total.is_a?(Integer) && total >= 0
            raise CommandError.new(
              "issue ##{number} 的 blockedBy.totalCount 缺失或非非负整数：#{total.inspect}，" \
              "拒绝把残缺响应当成无前置", command: args
            )
          end
          if total > nodes.length
            raise CommandError.new(
              "issue ##{number} 的 blockedBy 超过 #{BLOCKED_BY_PAGE} 条被截断，拒绝产出不完整依赖图",
              command: args
            )
          end
          # 回读的编号必须与请求一致：别名错位会让依赖张冠李戴。
          reported = node["number"]
          unless reported.to_i == number
            raise CommandError.new("blocked_by 批量结果错位：请求 ##{number}，返回 ##{reported}",
              command: args)
          end

          result[number] = nodes.map { |item| item.fetch("number").to_i }
        end
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

    # 全仓 issue 评论的本地索引：key 是评论 database id。
    #
    # 每个 source_ref 原本要两次独立请求（author + body），49 个引用就是 98 次；
    # 而本仓评论总数只有 4 页。一次全量分页把这段从 210.6s 降到 2.2s。
    #
    # 索引仅供命中，不作为缺失的兜底：ref 不在索引里必须回退单条请求，
    # 否则「评论已被删除/超出一页」会变成空正文——而 Evidence 校验对空正文是
    # 放行作者校验的，那等于 fail-open。
    def issue_comment_index
      @issue_comment_index ||= begin
        index = {}
        page = 1
        loop do
          batch = @runner.json!("gh", "api",
            "repos/#{@repo}/issues/comments?per_page=#{PAGE_SIZE}&page=#{page}")
          unless batch.is_a?(Array)
            raise CommandError.new("issue comments 分页返回非数组：#{batch.inspect[0, 200]}",
              command: ["gh", "api", "repos/#{@repo}/issues/comments"])
          end
          batch.each do |comment|
            id = comment.is_a?(Hash) ? comment["id"] : nil
            unless id.is_a?(Integer)
              raise CommandError.new("issue 评论缺 id：#{comment.inspect[0, 120]}",
                command: ["gh", "api", "repos/#{@repo}/issues/comments"])
            end
            index[id] = comment
          end
          break if batch.length < PAGE_SIZE

          page += 1
          if page > MAX_PAGES
            raise CommandError.new("issue comments 分页超过 #{MAX_PAGES} 页：#{@repo}",
              command: ["gh", "api", "repos/#{@repo}/issues/comments"])
          end
        end
        index
      end
    end

    def ref_body(ref)
      @body_cache[ref] ||= begin
        if (match = ref.match(%r{/issues/(\d+)#issuecomment-(\d+)})) ||
            (match = ref.match(%r{/pull/(\d+)#issuecomment-(\d+)}))
          comment = indexed_comment(match[2])
          # 未命中必须回退单条：评论可能超出分页范围或已被删除，
          # 空正文会让 Evidence 校验退化成「只验作者」。
          comment.nil? ? fetch_body("repos/#{@repo}/issues/comments/#{match[2]}") : indexed_body(comment, match[2])
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
          indexed_author(match[2]) || fetch_login("repos/#{@repo}/issues/comments/#{match[2]}")
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

    # 全量索引命中则直接返回，未命中返回 nil 交给调用方回退单条请求。
    def indexed_comment(id)
      issue_comment_index[id.to_i]
    end

    def indexed_author(id)
      comment = indexed_comment(id)
      return nil if comment.nil?

      login = comment.dig("user", "login")
      # 索引里存在但缺作者：结构非法，不能当「无人登记」放过去。
      raise CommandError.new("issue 评论 #{id} 缺 user.login：#{comment.inspect[0, 120]}",
        command: ["gh", "api", "repos/#{@repo}/issues/comments"]) if login.to_s.empty?

      login
    end

    # 命中记录的正文必须是字符串：缺失时 to_s 会静默变 ""，
    # 而空正文会让 Evidence 校验只验作者——那正是本索引要防的 fail-open。
    # 合法的空字符串正文照常放行（评论内容本身可以为空）。
    def indexed_body(comment, id)
      body = comment["body"]
      unless body.is_a?(String)
        raise CommandError.new("issue 评论 #{id} 的 body 缺失或非字符串：#{body.inspect}",
          command: ["gh", "api", "repos/#{@repo}/issues/comments"])
      end

      body
    end

    def fetch_login(path)
      @runner.json!("gh", "api", path).dig("user", "login")
    end

    def fetch_body(path)
      raw = @runner.json!("gh", "api", path)
      raw["body"].to_s
    end

    def attach_blocked_by(issues)
      target = issues.select { |issue| JsonBlock.present?(issue.body, "automation") }
      bulk = fetch_blocked_by_batch(target.map(&:number))
      # 批量结果同时写进单卡缓存：之后 fetch_blocked_by 读同一张卡直接命中。
      bulk.each { |number, blocked| @blocked_cache[number] = blocked }

      issues.map do |issue|
        next issue unless JsonBlock.present?(issue.body, "automation")

        issue.with(blocked_by: bulk.fetch(issue.number))
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
    #
    # 清单本身不带 CI 汇总（见 PULL_REQUEST_LIST_QUERY 的说明）：
    #   - open PR 在明细阶段单独取 checks（选择器与 pre 核验要判 CI）；
    #   - 其余 PR 留 nil，表示「未取」，不是「没有检查」；
    #   - verify merge 需要的目标 PR 由 checks_for 按编号补取。
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
        args = ["gh", "api", "graphql", "-f", "query=#{PULL_REQUEST_LIST_QUERY}",
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
        # checks 的取值口径：列表不再带 rollup，所以这里的 key 缺失是常态。
        # open PR 必须补齐（选择器要判 CI、pre 核验要拦未完成），
        # 其余留 nil 表示「未取」，与「检查为空」区分开——下游据此判断是否可判定。
        checks = if item.key?("statusCheckRollup")
          normalize_checks(item["statusCheckRollup"])
        elsif item["state"].to_s.casecmp?("OPEN")
          fetch_checks(item["number"], expected_head: item["headRefOid"])
        end
        Model::PullRequest.from_hash(
          "number" => item["number"],
          "head_ref_name" => item["headRefName"],
          "base_ref_name" => item["baseRefName"],
          "head_sha" => item["headRefOid"],
          "state" => item["state"],
          "merge_state_status" => item["mergeStateStatus"],
          "checks" => checks,
          "review_threads" => threads,
          "closing_issues" => Array(item["closingIssuesReferences"]).map { |ref| ref["number"] },
          "url" => item["url"]
        ).merge_pr_details(details)
      end
    end

    # 按编号取单个 PR 的 CI 汇总，返回与 normalize_checks 一致的形状。
    # 供 open PR 组装与 verify merge 的目标 PR 复核使用。
    # 结构与截断校验与列表口径一致：读不到就抛错，不当空集。
    #
    # expected_head：调用方快照记录的 head sha。statusCheckRollup 反映的是
    # PR **当前** head 的检查，而快照的 head_sha/files 属于采集时刻的 head。
    # 两次请求之间 PR 若推了新提交，返回的 checks 就属于另一个 commit——
    # 用它去判 A 的合并会把 B 的绿灯当成 A 的绿灯。因此这里回读 headRefOid
    # 并强校验，不一致即拒绝（与 fetch_pr_details 的既有守卫同口径）。
    def fetch_checks(number, expected_head: nil)
      owner, name = @repo.split("/", 2)
      fields = "p: pullRequest(number: #{number}) { number headRefOid statusCheckRollup " \
        "{ contexts(first: #{ROLLUP_PAGE}) { pageInfo { hasNextPage } nodes " \
        "{ __typename ... on CheckRun { name status conclusion } ... on StatusContext { context state } } } } }"
      args = ["gh", "api", "graphql",
        "-f", "query=#{blocked_by_query(owner, name, [fields])}"]
      payload = @runner.json!(*args)
      errors = payload["errors"]
      unless errors.nil? || (errors.respond_to?(:empty?) && errors.empty?)
        raise CommandError.new("PR ##{number} checks 查询失败：#{errors.inspect}", command: args)
      end
      node = payload.dig("data", "repository", "p")
      unless node.is_a?(Hash) && node["number"].to_i == number
        raise CommandError.new("PR ##{number} checks 查询缺对应节点（结构非法，不当空集）", command: args)
      end
      ensure_checks_head!(number, node["headRefOid"], expected_head, args)

      rollup = node["statusCheckRollup"]
      # 显式 null = 检查未产出（合法空集）；字段缺失 = 结构非法。
      return [] if node.key?("statusCheckRollup") && rollup.nil?

      contexts = rollup.is_a?(Hash) ? rollup["contexts"] : nil
      page_info = contexts.is_a?(Hash) ? contexts["pageInfo"] : nil
      nodes = contexts.is_a?(Hash) ? contexts["nodes"] : nil
      unless page_info.is_a?(Hash) && (page_info["hasNextPage"] == true || page_info["hasNextPage"] == false) &&
          nodes.is_a?(Array)
        raise CommandError.new("PR ##{number} 的 statusCheckRollup 结构非法：#{rollup.inspect[0, 120]}",
          command: args)
      end
      if page_info["hasNextPage"]
        raise CommandError.new("PR ##{number} 的 contexts 超过 #{ROLLUP_PAGE} 条被截断，拒绝产出不完整检查清单",
          command: args)
      end

      normalize_checks(nodes)
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
      closing_nodes = inner_nodes.call(["closingIssuesReferences"], 10)
      {
        "number" => node["number"],
        "headRefName" => node["headRefName"],
        "baseRefName" => node["baseRefName"],
        "headRefOid" => node["headRefOid"],
        "state" => node["state"],
        "mergeStateStatus" => node["mergeStateStatus"],
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

    # GraphQL 查询外壳：别名列表由调用方拼；owner/name 作为字面量嵌入，
    # 避免再占两个变量位（本查询没有游标，不需要变量化）。
    def blocked_by_query(owner, name, fields)
      %(query { repository(owner: "#{owner}", name: "#{name}") { #{fields.join(" ")} } })
    end

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

    # checks 的 head 守卫：expected_head 为 nil 时（离线/无快照 head）不做比对，
    # 一旦给了就必须严格相等；回读值缺失同样拒绝。
    def ensure_checks_head!(number, actual_head, expected_head, args)
      return if expected_head.nil?

      if actual_head.to_s.empty?
        raise CommandError.new(
          "PR ##{number} 的 checks 查询缺 headRefOid，无法确认与快照同 head；拒绝（fail-closed）",
          command: args
        )
      end
      return if actual_head.to_s == expected_head.to_s

      raise CommandError.new(
        "PR ##{number} 在采集期间推进了 head（快照=#{expected_head}，当前=#{actual_head}）；" \
        "checks 属于另一个 commit，拒绝拼成混合快照",
        command: args
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
