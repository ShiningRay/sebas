# frozen_string_literal: true

require "json"

module Sebas
  module Providers
    # ReAct 工具调用解析（M4.3-WP1，Q3 裁断 ReAct 落位 gateway agent_turn）：
    # 模型以固定 JSON 块发起工具调用——
    #   ```json
    #   {"tool": "memory.search", "args": {"query": "..."}}
    #   ```
    # 含该结构即视为工具调用轮（继续循环）；不含即终答（行为与现状一致）。
    # 解析为纯函数：块缺失/JSON 非法/字段缺失/tool 非字符串 → nil（终答），
    # 不抛异常——解析失败按模型说了人话处理，不中断 turn。
    module ToolCallParser
      record Call, tool : String, args : JSON::Any

      def self.parse(text : String) : Call?
        start = text.index("```json")
        return if start.nil?
        # 从 ```json 之后按括号平衡扫描提取完整 JSON 值（字符串内的 }
        # 与 ``` 序列不构成边界——args 含反引号/花括号时朴素正则会提前截断）
        body_start = start + "```json".size
        json_text = balanced_json(text, body_start)
        return if json_text.nil?
        begin
          data = JSON.parse(json_text).as_h
          tool = data["tool"]?.try(&.as_s?)
          args = data["args"]? || JSON::Any.new({} of String => JSON::Any)
          return if tool.nil? || tool.empty? || args.as_h?.nil?
          Call.new(tool, args)
        rescue JSON::ParseException | TypeCastError
          nil
        end
      end

      # 括号平衡扫描：从 pos 起提取第一个完整 JSON 对象（跟踪字符串状态与
      # 转义——字符串内的 } / ``` 不计入深度）。无完整对象返回 nil。
      private def self.balanced_json(text : String, pos : Int32) : String?
        depth = 0
        in_string = false
        escaped = false
        start_idx = -1
        text.each_char_with_index do |char, pos_idx|
          next if pos_idx < pos
          if escaped
            escaped = false
            next
          end
          if in_string
            escaped = true if char == '\\'
            in_string = false if char == '"'
            next
          end
          case char
          when '"' then in_string = true
          when '{'
            start_idx = pos_idx if depth.zero?
            depth += 1
          when '}'
            depth -= 1
            return text[start_idx..pos_idx] if depth.zero? && start_idx >= 0
          end
        end
        nil
      end
    end
  end
end
