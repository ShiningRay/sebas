# frozen_string_literal: true

require "json"

module SebasAgents
  # 从 gh CLI 构造 GitHub 事实源快照。
  # 只读：本类不调用任何写接口；写动作集中在 Implementer 适配器中。
  # 网络调用做了缓存与批量补齐，避免逐 issue 往返。
  class GithubGateway
    PAGE_SIZE = 100
    PAGE_LIMIT_WARNING = 100
    MAX_PAGES = 100
    MAX_DEPENDENCY_FETCH = 300

    def initialize(runner, repo:)
      @runner = runner
      @repo = repo
      @issue_cache = {}
      @blocked_cache = {}
      @thread_cache = {}
      @author_cache = {}
    end

    def snapshot(gate_records: {}, external_records: {})
      milestones = fetch_milestones
      issues = fetch_all_issues
      pull_requests = fetch_pull_requests
      issues = attach_blocked_by(issues)
      issues = close_over_dependencies(issues)

      blocks = issues.filter_map { |issue| JsonBlock.one(issue.body, "evidence", subject: "issue ##{issue.number}") }
      discovered = discover_records(blocks)
      Model::Snapshot.new(
        repo: @repo,
        main_sha: main_sha,
        milestones: milestones,
        issues: issues,
        pull_requests: pull_requests,
        maintainers: maintainers,
        source_authors: resolve_authors(blocks),
        gates: discovered["gates"].merge(gate_records),
        externals: discovered["externals"].merge(external_records)
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

    def resolve_authors(blocks)
      blocks.each_with_object({}) do |block, memo|
        ref = block["source_ref"].to_s
        next if ref.empty? || memo.key?(ref)

        memo[ref] = ref_author(ref)
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
        "url" => raw["html_url"]
      )
    end

    def parse_automation(body, number)
      JsonBlock.one(body, "automation", subject: "issue ##{number}")
    rescue InvalidPlan
      # 解析失败留给 Dependencies.automation_for 报出具体原因，
      # 这里不静默伪装成"有元数据"。
      nil
    end

    def fetch_pull_requests
      raw = @runner.json!("gh", "pr", "list", "--repo", @repo, "--state", "all", "--limit", "100",
        "--json", "number,headRefName,baseRefName,headRefOid,state,mergeStateStatus,statusCheckRollup,closingIssuesReferences,url,isCrossRepository")
      unless raw.is_a?(Array)
        raise CommandError.new("pr list 返回非数组：#{raw.inspect[0, 200]}", command: ["gh", "pr", "list"])
      end
      # gh pr list 单页上限：达到上限时数据可能被截断，不能静默当成全量。
      if raw.length >= PAGE_LIMIT_WARNING
        raise CommandError.new(
          "PR 列表达到单页上限 #{PAGE_LIMIT_WARNING}，可能截断在途 PR；请改用 gh api 分页",
          command: ["gh", "pr", "list"]
        )
      end
      raw.reject { |item| item["isCrossRepository"] }.map do |item|
        # 只有 open PR 需要未解决 thread；已合并/关闭的 PR 不发起 GraphQL 往返。
        threads = item["state"].to_s.casecmp?("OPEN") ? fetch_review_threads(item["number"]) : []
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
        )
      end
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
