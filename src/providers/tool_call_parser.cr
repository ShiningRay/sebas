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

      PATTERN = /```json\s*(\{.*?\})\s*```/m

      def self.parse(text : String) : Call?
        match = PATTERN.match(text)
        return if match.nil?
        begin
          data = JSON.parse(match[1]).as_h
          tool = data["tool"]?.try(&.as_s?)
          args = data["args"]? || JSON::Any.new({} of String => JSON::Any)
          return if tool.nil? || tool.empty? || args.as_h?.nil?
          Call.new(tool, args)
        rescue JSON::ParseException | TypeCastError
          nil
        end
      end
    end
  end
end
