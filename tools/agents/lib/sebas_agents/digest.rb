# frozen_string_literal: true

module SebasAgents
  # Proposal 评论索引：把散落的研判评论压成一条置顶索引，结论区留给人写。
  #
  # 分工边界：
  #   - 工具只做机械部分：判定时间线、评论计数、链接锚点。这些能从评论确定性提取。
  #   - 「已达成 / 待裁决」是语义判断，工具不猜；留给人工摘要区，工具永不覆盖。
  module Digest
    MARKER = "<!-- proposal-digest -->"
    MANUAL_MARKER = "<!-- digest:manual -->"
    ARCH_MARKER = "<!-- arch: issue-arch -->"
    # 摘要评论自身必须被所有自动化识别并丢弃，否则每写一次摘要就触发一轮研判。
    CIRCUIT_BREAKER = "<!-- proposal-digest:auto -->"
    STATUS_PATTERN = /\A<!--\s*status:\s*([a-z-]+)\s*-->\s*$/
    EVIDENCE_MARKER = "<!-- evidence-register:bot -->"

    module_function

    # 从评论正文提取 status 标记；只认首行，避免正文里引用标记被误判。
    def status_of(body)
      first = body.to_s.lines.first.to_s.strip
      # digest 评论首行是自身标记，不能被误认成研判；它也不该驱动研判计数。
      return nil if first.include?(MARKER)

      match = STATUS_PATTERN.match(first)
      match && match[1]
    end

    def jarvis?(body)
      body.to_s.include?(ARCH_MARKER)
    end

    def machine?(comment)
      body = comment["body"].to_s
      body.include?(EVIDENCE_MARKER) || comment.dig("user", "type") == "Bot"
    end

    # 已有置顶索引里人工写的部分：标记行之后原样保留。
    def manual_section(existing_body)
      text = existing_body.to_s
      index = text.index(MANUAL_MARKER)
      return "" if index.nil?

      text[(index + MANUAL_MARKER.length)..].to_s
    end

    def existing(comments)
      comments.find { |comment| comment["body"].to_s.include?(MARKER) }
    end

    # 生成完整索引正文。existing 为当前置顶评论（可能为 nil），用于保留人工区。
    def build(issue, comments, existing_body: nil)
      judgments = comments.filter_map do |comment|
        status = status_of(comment["body"])
        next unless status && jarvis?(comment["body"])

        {
          "status" => status,
          "at" => comment["created_at"].to_s,
          "url" => comment["html_url"].to_s,
          "author" => comment.dig("user", "login").to_s
        }
      end
      others = comments.reject { |comment| comment["body"].to_s.include?(MARKER) }
      human = others.reject { |comment| status_of(comment["body"]) && jarvis?(comment["body"]) }
      human = human.reject { |comment| machine?(comment) }

      latest = judgments.max_by { |item| item["at"] }
      lines = []
      lines << MARKER
      lines << CIRCUIT_BREAKER
      lines << "## 当前状态（工具维护，请勿手改本节）"
      lines << ""
      lines << "| 项 | 值 |"
      lines << "|---|---|"
      lines << "| Proposal | ##{issue["number"]} #{issue["title"].to_s.delete("|")} |"
      lines << "| 最新判定 | #{latest ? "`#{latest["status"]}`" : "尚无研判"} |"
      lines << "| 最近研判 | #{latest ? latest["at"][0, 10] : "-"} |"
      lines << "| 研判次数 | #{judgments.length} |"
      lines << "| 人工评论 | #{human.length} 条 |"
      lines << ""
      if judgments.empty?
        lines << "尚无 Triager 研判评论。"
      else
        lines << "### 研判时间线"
        lines << ""
        lines << "| # | 日期 | 判定 | 链接 |"
        lines << "|---|---|---|---|"
        judgments.sort_by { |item| item["at"] }.each_with_index do |item, index|
          lines << "| #{index + 1} | #{item["at"][0, 10]} | `#{item["status"]}` | [评论](#{item["url"]}) |"
        end
      end
      lines << ""
      lines << "**读取顺序**：先看下方人工摘要，再按需点上表链接核对原始研判。"
      lines << ""
      lines << MANUAL_MARKER
      manual = manual_section(existing_body)
      if manual.strip.empty?
        lines << ""
        lines << "### 已达成"
        lines << ""
        lines << "- （待填）"
        lines << ""
        lines << "### 待裁决"
        lines << ""
        lines << "- （待填）"
      else
        lines << manual.rstrip
      end
      lines.join("\n") + "\n"
    end
  end
end
