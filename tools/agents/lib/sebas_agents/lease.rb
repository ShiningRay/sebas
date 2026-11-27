# frozen_string_literal: true

require "json"
require "securerandom"

module SebasAgents
  # per-issue 租约（M4x-Parallel-WP2，#220；Proposal parallel-implementers.md §5、续篇 §3）。
  #
  # GitHub 侧凭据（Q1=B 裁决）：带 marker 的协调评论，comment id 即 lease_id。
  # 唯一性判据：同一 issue 的 `state != released` 有效租约评论恰有一条，
  # 多于一条即 invalid_plan（F9）；作者必须在 .github/agents.yml 的
  # coordinators 白名单内（作者绑定，口径同 Evidence 的 source_ref 回查）。
  # `agent:in-progress` 标签只是人类可见信号：有标签而无有效凭据即
  # invalid_plan（F7 孤儿标签），标签永不作为所有权证明。
  module Lease
    MARKER = "<!-- sebas-lease -->"
    STATE_ACTIVE = "active"
    STATE_RELEASED = "released"
    CREDENTIAL_FIELDS = %w[lease_id issue branch base_sha coordinator_id host state claimed_at].freeze

    INVALID_AUTHOR = "coordinator_not_authorized"
    INVALID_DUPLICATE = "duplicate_lease"
    INVALID_MALFORMED = "lease_malformed"

    module_function

    # 生成 lease_id：coordinator 在发评论前生成，崩溃恢复时据此检索复用（续篇 F1）。
    def new_lease_id
      SecureRandom.uuid
    end

    # 租约评论正文：marker + JSON 凭据（字段闭集）。发出后只改一次——
    # 释放时把 state 改为 released；不承载心跳之外的语义。
    def comment_body(lease_id:, issue:, branch:, base_sha:, coordinator_id:, host:,
                     claimed_at:, state: STATE_ACTIVE)
      credential = {
        "lease_id" => lease_id,
        "issue" => issue,
        "branch" => branch,
        "base_sha" => base_sha,
        "coordinator_id" => coordinator_id,
        "host" => host,
        "state" => state,
        "claimed_at" => claimed_at
      }
      "#{MARKER}\n```json sebas-lease\n#{JSON.pretty_generate(credential)}\n```\n"
    end

    # 解析一条 GitHub 评论（{id, user:{login}, body} 形状）。
    # 非租约评论返回 nil；带 marker 的评论必须含合法 JSON 凭据且字段闭集，
    # 否则按 fail-closed 上抛 InvalidPlan（内容被篡改不可静默忽略）。
    def parse_comment(comment)
      body = comment["body"].to_s
      return nil unless body.include?(MARKER)

      json_start = body.index("```json sebas-lease")
      raise InvalidPlan, "租约评论 #{comment["id"]} 缺 sebas-lease 代码块" unless json_start

      rest = body[(json_start + "```json sebas-lease".length)..].to_s
      json_text = rest.split("```").first.to_s
      credential = begin
        JSON.parse(json_text)
      rescue JSON::ParserError => e
        raise InvalidPlan, "租约评论 #{comment["id"]} 的凭据不是合法 JSON：#{e.message}"
      end
      missing = CREDENTIAL_FIELDS.reject { |field| credential.key?(field) }
      unless missing.empty?
        raise InvalidPlan, "租约评论 #{comment["id"]} 凭据缺字段：#{missing.join('、')}"
      end

      {id: comment["id"], login: comment.dig("user", "login").to_s, credential: credential}
    end

    # 对一条已解析的租约做作者与状态校验。
    # 返回 credential（Hash）；作者不在白名单 → InvalidPlan（作者绑定）。
    def authorize(parsed, author_whitelist)
      login = parsed[:login]
      raise InvalidPlan, "租约评论作者 #{login.inspect} 不在 coordinators 白名单，按 fail-closed 处理" unless author_whitelist.include?(login)

      parsed[:credential]
    end

    # 唯一性扫描（F9）：state != released 的有效租约恰为一条。
    # 返回该租约的 credential（Hash）；零条返回 nil。
    # 多条 active、或任何租约评论解析/作者校验失败，都上抛 InvalidPlan——
    # 全仓停止认领，交 Maintainer 处置，不得按时间或 id 猜测取一条。
    def active_lease(comments, author_whitelist:)
      active = []
      comments.each do |comment|
        parsed = parse_comment(comment)
        next unless parsed

        credential = authorize(parsed, author_whitelist)
        active << credential if credential["state"] != STATE_RELEASED
      end
      return nil if active.empty?

      raise InvalidPlan, "同一张卡有 #{active.length} 份有效租约凭据（F9）：全仓停止认领，需 Maintainer 处置" if active.length > 1

      active.first
    end

    # F7 孤儿标签：`agent:in-progress` 在而有效凭据不在 → invalid_plan。
    def assert_no_orphan_label(label_present:, active_lease:, issue_number:)
      return unless label_present
      return if active_lease

      raise InvalidPlan, "issue ##{issue_number} 带 #{Model::IN_PROGRESS_LABEL.inspect} 但无有效租约凭据（F7）：所有权不明，按 fail-closed 处理"
    end

    # 按 lease_id 检索既有租约评论（续篇 F1/F4 恢复路径）。
    # 返回 [comment_id, credential]；未找到返回 nil。解析失败仍上抛。
    def find_by_lease_id(comments, lease_id, author_whitelist:)
      comments.each do |comment|
        parsed = parse_comment(comment)
        next unless parsed
        next unless parsed[:credential]["lease_id"] == lease_id

        credential = authorize(parsed, author_whitelist)
        return [parsed[:id], credential]
      end
      nil
    end
  end
end
