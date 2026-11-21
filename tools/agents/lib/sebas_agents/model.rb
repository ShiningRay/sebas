# frozen_string_literal: true

require "time"

module SebasAgents
  # 纯值对象：全部由 JSON 快照构造，不含网络或文件副作用。
  module Model
    IN_PROGRESS_LABEL = "agent:in-progress"
    RESUME_LABEL = "agent:resume"
    HUMAN_LABEL = "needs:human"
    INVALID_LABEL = "metadata:invalid"

    Milestone = Data.define(:number, :title, :state, :order, :track, :open_issues, :description) do
      def main?
        track == "main"
      end

      def open?
        state == "open"
      end

      def sort_key
        Integer(order, 10)
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
      :assignees, :blocked_by, :automation, :url) do
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
          url: hash["url"]
        )
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
    end

    PullRequest = Data.define(:number, :branch, :base, :head_sha, :state, :merged,
      :merge_state_status, :checks, :review_threads, :closing_issues, :url) do
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
          url: hash["url"]
        )
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
      :source_authors, :gates, :externals, :trusted_bots, :source_bodies) do
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
          source_bodies: hash["source_bodies"] || {}
        )
      end

      def issue(number)
        issues.find { |item| item.number == number }
      end

      def pull_request(number)
        pull_requests.find { |item| item.number == number }
      end

      def in_progress_issues
        issues.select { |item| item.open? && item.label?(IN_PROGRESS_LABEL) }
      end

      def with(**changes)
        self.class.new(**to_h.merge(changes))
      end
    end

    # 选卡结果。action 取值见 docs/design/process/implementer-loop.md §4。
    Action = Data.define(:action, :milestone, :issue, :reason, :observed_main, :excluded) do
      def to_h
        {
          "action" => action,
          "milestone" => milestone,
          "issue" => issue,
          "reason" => reason,
          "observed_main" => observed_main,
          "excluded" => excluded
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
