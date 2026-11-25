# frozen_string_literal: true

require "time"

module SebasAgents
  # 纯值对象：全部由 JSON 快照构造，不含网络或文件副作用。
  module Model
    RESUME_LABEL = "agent:resume"
    HUMAN_LABEL = "needs:human"
    INVALID_LABEL = "metadata:invalid"

    # 账号级 Issue Status。执行状态只认 status，不再用 agent:in-progress 标签。
    # 名称必须与 GitHub 上的显示名一致（大小写不敏感，但这里统一用官方写法）。
    STATUS_BACKLOG = "Backlog"
    STATUS_TODO = "Todo"
    STATUS_IN_PROGRESS = "In progress"
    STATUS_IN_REVIEW = "In review"
    STATUS_DONE = "Done"
    STATUS_NOT_PLANNED = "Not planned"
    STATUS_DUPLICATE = "Duplicate"
    WORKING_STATUSES = [STATUS_IN_PROGRESS, STATUS_IN_REVIEW].freeze

    # Issue Type：按性质分派流程。Task 指文档/CI/工具/流程类工作。
    # Proposal 是账号级原生类型（2026-11 建立）：讨论定稿后才拆实现卡，不进 Implementer 选卡。
    TYPE_BUG = "Bug"
    TYPE_FEATURE = "Feature"
    TYPE_TASK = "Task"
    TYPE_PROPOSAL = "Proposal"
    TYPES = [TYPE_BUG, TYPE_FEATURE, TYPE_TASK, TYPE_PROPOSAL].freeze

    Milestone = Data.define(:number, :title, :state, :order, :track, :open_issues, :description) do
      def main?
        track == "main"
      end

      def parallel?
        track == "parallel"
      end

      def open?
        state == "open"
      end

      # 只用于 track=main。并行轨的 order 带 x 后缀，走 parallel_sort_key。
      def sort_key
        Integer(order, 10)
      end

      # 并行轨排序看数值前缀：4x 与 4 同序号，但两者分属不同轨，互不竞争。
      def parallel_sort_key
        Integer(order.to_s.delete_suffix("x"), 10)
      end

      def self.from_hash(hash)
        new(
          number: hash.fetch("number"),
          title: hash.fetch("title", ""),
          state: hash.fetch("state", "open"),
          order: hash["order"],
          track: hash["track"],
          open_issues: hash.fetch("open_issues", 0).to_i,
          description: hash["description"].to_s
        )
      end
    end

    Issue = Data.define(:number, :title, :state, :state_reason, :body, :labels, :milestone,
      :assignees, :blocked_by, :automation, :url, :type, :status) do
      def self.from_hash(hash)
        milestone = hash["milestone"].is_a?(Hash) ? hash["milestone"]["number"] : hash["milestone"]
        new(
          number: hash.fetch("number").to_i,
          title: hash.fetch("title", ""),
          state: hash.fetch("state", "OPEN").to_s,
          state_reason: hash["state_reason"],
          body: hash["body"].to_s,
          labels: names(hash["labels"]),
          milestone: milestone.nil? ? nil : milestone.to_i,
          assignees: names(hash["assignees"]),
          blocked_by: Array(hash["blocked_by"]).map(&:to_i),
          # 离线快照只有 body；若不解析，所有工作包都会被判成「缺 Automation 块」。
          # 与 GithubGateway#build_issue 保持同一解析口径。
          automation: hash.key?("automation") ? hash["automation"] : parse_automation(hash["body"].to_s, hash.fetch("number").to_i),
          url: hash["url"],
          # type/status 缺失是合法状态（存量卡未回填），不报错；由业务层决定如何处理。
          type: name_of(hash["type"]),
          status: name_of(hash["status"])
        )
      end

      # GitHub 的 type / status 都是对象；也接受直接给字符串（离线快照方便）。
      def self.name_of(value)
        case value
        when Hash then value["name"]&.to_s
        when String then value.empty? ? nil : value
        end
      end

      def self.parse_automation(body, number)
        JsonBlock.one(body, "automation", subject: "issue ##{number}")
      end

      def self.names(value)
        Array(value).map { |item| item.is_a?(Hash) ? item.fetch("name", item.fetch("login", "")) : item.to_s }
      end

      def label?(name)
        labels.include?(name)
      end

      # Proposal 判定：标签与原生 type 任一命中即算。
      # 迁移期五张存量卡里仍有 type=Feature 的，不能因为 type 缺失就漏判。
      def proposal?
        label?("proposal") || type == TYPE_PROPOSAL
      end

      def closed?
        state.casecmp?("CLOSED")
      end

      def open?
        !closed?
      end

      # 只有 completed 算完成；not planned 不算。见 §2.3。
      def completed?
        closed? && state_reason.to_s.casecmp?("COMPLETED")
      end

      def kind
        automation && automation["kind"]
      end

      # 已排期：挂了 milestone。plan 标签退出历史舞台，排期只看 milestone。
      def scheduled?
        !milestone.nil?
      end

      # 独立小修：Task、无 milestone、声明为可执行工作包、且显式声明「无前置」。
      # 它是唯一合法的「无 milestone 却可开工」形态，只走人工 claim，不进自动选卡。
      #
      # 必须要求 depends_on 显式为 []：带依赖却无 milestone 的卡既没有容量与 DAG 约束，
      # 又自称有前置，是矛盾状态，不能借「小修」名义绕过缺口检查。
      def small_fix?
        return false if scheduled? || type != TYPE_TASK || kind != "work_package"

        automation["depends_on"].is_a?(Array) && automation["depends_on"].empty?
      end

      # 执行中：In progress / In review。认领锁改由 status 承担。
      def working?
        WORKING_STATUSES.any? { |name| status?(name) }
      end

      def type?(name)
        type.to_s.casecmp?(name)
      end

      def status?(name)
        status.to_s.casecmp?(name)
      end

      def backlog?
        status?(STATUS_BACKLOG)
      end
    end

    PullRequest = Data.define(:number, :branch, :base, :head_sha, :state, :merged,
      :merge_state_status, :checks, :review_threads, :closing_issues, :url,
      :files, :body) do
      def self.from_hash(hash)
        new(
          number: hash.fetch("number").to_i,
          branch: hash["head_ref_name"].to_s,
          base: hash["base_ref_name"].to_s,
          head_sha: hash["head_sha"].to_s,
          state: hash.fetch("state", "OPEN").to_s.upcase,
          merged: hash.fetch("merged", false) == true,
          merge_state_status: hash["merge_state_status"].to_s,
          checks: Array(hash["checks"]),
          review_threads: Array(hash["review_threads"]),
          closing_issues: Array(hash["closing_issues"]).map(&:to_i),
          url: hash["url"],
          # #125：变更文件与正文由 gateway 对 open PR 填充；离线快照缺省为 nil 时
          # 路径联动/安全/CWE 检查不可判定，verify_merge 按未执行留痕。
          files: hash.key?("files") ? hash["files"] : nil,
          body: hash.key?("body") ? hash["body"].to_s : nil
        )
      end

      # #125：gateway 取回的正文/变更文件合并为带数据的新实例（Data 不可变）。
      def merge_pr_details(details)
        return self if details.nil? || details.empty?

        with(files: details["files"], body: details["body"].to_s)
      end

      def merged?
        merged || state == "MERGED"
      end

      def open?
        state == "OPEN"
      end

      def unresolved_threads
        review_threads.reject { |thread| thread["isResolved"] == true }
      end

      def failing_checks
        checks.select do |check|
          %w[FAILURE ERROR CANCELLED TIMED_OUT ACTION_REQUIRED].include?(check["conclusion"].to_s.upcase)
        end
      end

      def pending_checks
        checks.select do |check|
          status = check["status"].to_s.upcase
          !status.empty? && status != "COMPLETED"
        end
      end

      def green?
        checks.any? && failing_checks.empty? && pending_checks.empty?
      end

      def checks_green?
        failing_checks.empty? && pending_checks.empty?
      end
    end

    # 快照：GitHub 事实源的不可变副本。source_authors 为 source_ref → 登录名。
    # gates / externals 为 subject → Evidence 块，供依赖判定读取。
    # trusted_bots 为 .github/agents.yml 授权的 bot 身份（如 "github-actions[bot]"），
    # 供 Evidence 的 workflow 登记路径校验；人类 Maintainer 仍走 maintainers。
    Snapshot = Data.define(:repo, :main_sha, :milestones, :issues, :pull_requests, :maintainers,
      :source_authors, :gates, :externals, :trusted_bots, :source_bodies, :proposal_evidence) do
      def self.from_hash(hash)
        new(
          repo: hash.fetch("repo", ""),
          main_sha: hash.fetch("main_sha", ""),
          milestones: Array(hash["milestones"]).map { |item| Milestone.from_hash(item) },
          issues: Array(hash["issues"]).map { |item| Issue.from_hash(item) },
          pull_requests: Array(hash["pull_requests"]).map { |item| PullRequest.from_hash(item) },
          maintainers: Array(hash["maintainers"]).map(&:to_s),
          source_authors: hash["source_authors"] || {},
          gates: hash["gates"] || {},
          externals: hash["externals"] || {},
          trusted_bots: Array(hash["trusted_bots"]).map(&:to_s),
          # source_ref → 被引用评论正文。用于校验「登记内容」而非仅「作者身份」。
          source_bodies: hash["source_bodies"] || {},
          # Proposal 裁决单独存真实作者、正文与父对象，缺省视为不可核验。
          proposal_evidence: hash["proposal_evidence"] || {}
        )
      end

      def issue(number)
        issues.find { |item| item.number == number }
      end

      def pull_request(number)
        pull_requests.find { |item| item.number == number }
      end

      # 认领锁只覆盖实现类工作卡：Proposal 可以处于 In progress（讨论设计中），
      # 但它不是 Implementer 的认领对象，不能占用「同时只有一张」的名额。
      def in_progress_issues
        issues.select { |item| item.open? && item.working? && !item.proposal? }
      end

      def with(**changes)
        self.class.new(**to_h.merge(changes))
      end
    end

    # 选卡结果。action 取值见 docs/design/process/implementer-loop.md §4。
    # metadata_gaps 列出「看起来是工作包却挂不到 active milestone」的卡，
    # 用于避免它们只表现为笼统的「元数据未补齐」。
    Action = Data.define(:action, :milestone, :issue, :reason, :observed_main, :excluded,
      :metadata_gaps) do
      def self.from_h(hash)
        new(action: hash["action"], milestone: hash["milestone"], issue: hash["issue"],
          reason: hash["reason"], observed_main: hash["observed_main"],
          excluded: hash["excluded"] || [], metadata_gaps: hash["metadata_gaps"] || [])
      end

      def to_h
        {
          "action" => action,
          "milestone" => milestone,
          "issue" => issue,
          "reason" => reason,
          "observed_main" => observed_main,
          "excluded" => excluded,
          "metadata_gaps" => metadata_gaps
        }.compact
      end
    end

    Evaluation = Data.define(:status, :reasons) do
      def ready?
        status == "ready"
      end

      def invalid?
        status == "invalid"
      end
    end
  end
end
