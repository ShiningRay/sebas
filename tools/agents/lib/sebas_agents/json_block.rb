# frozen_string_literal: true

require "json"

module SebasAgents
  # 解析 issue / PR body 中带 info string 的 JSON 代码块。
  # 约定：```json automation / ```json evidence
  module JsonBlock
    FENCE = /^```json[ \t]+([a-z][a-z0-9_-]*)[ \t]*\r?\n(.*?)^```[ \t]*$/m

    module_function

    def blocks(body, kind)
      body.to_s.scan(FENCE).filter_map do |info, json|
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
      body.to_s.scan(FENCE).any? { |info, _| info == kind }
    end
  end
end
