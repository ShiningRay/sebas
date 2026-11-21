# frozen_string_literal: true

require "json"

module SebasAgents
  # 解析 issue / PR body 中带 info string 的 JSON 代码块。
  # 约定：```json automation / ```json evidence
  #
  # body 可能来自 Windows 客户端（CRLF），因此统一按 LF 匹配；
  # 否则换行差异会让所有元数据"看起来不存在"。
  module JsonBlock
    FENCE = /^```json[ \t]+([a-z][a-z0-9_-]*)[ \t]*\n(.*?)^```[ \t]*$/m

    module_function

    def blocks(body, kind)
      normalize(body).scan(FENCE).filter_map do |info, json|
        next unless info == kind

        begin
          JSON.parse(json)
        rescue JSON::ParserError => e
          raise InvalidPlan, "#{kind} 块不是合法 JSON：#{e.message}"
        end
      end
    end

    # 同一 body 内最多一个块；多个块视为元数据冲突。
    def one(body, kind, subject:)
      found = blocks(body, kind)
      raise InvalidPlan, "#{subject} 出现 #{found.length} 个 #{kind} 块" if found.length > 1

      found.first
    end

    def present?(body, kind)
      blocks(body, kind).any?
    end

    def normalize(body)
      body.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
    end
  end
end
