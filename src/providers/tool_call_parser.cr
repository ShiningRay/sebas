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

      # 协议约束（CodeRabbit DUuZ）：围栏内必须是完整 JSON 值（顶层对象、
      # 无尾随内容——对象后藏料即无效）；args 字符串值不得含 ``` 序列
      # （字符串内的 } 与 ``` 不构成边界——括号平衡扫描跟踪字符串状态）。
      def self.parse(text : String) : Call?
        json_text, content_end, closing = extract_block(text)
        return if json_text.nil?
        # JSON 之后（含末 } 的下一字符起）到闭合围栏之间不得有非空白内容
        # （对象后藏料即无效）；无闭合围栏 = 残缺协议，同样拒绝。
        return unless text[content_end...closing].strip.empty?
        begin
          parsed = JSON.parse(json_text)
          return unless parsed.as_h?
          data = parsed.as_h
          tool = data["tool"]?.try(&.as_s?)
          args = data["args"]? || JSON::Any.new({} of String => JSON::Any)
          return if tool.nil? || tool.empty? || args.as_h?.nil?
          Call.new(tool, args)
        rescue JSON::ParseException | TypeCastError
          nil
        end
      end

      # 括号平衡扫描（单遍、统一字符坐标系）：从开栏 ```json 起提取完整
      # JSON 对象，定位闭合围栏。字符串内的 } / ``` 不构成边界（跟踪字符串
      # 状态与转义）。返回 {json_text, 内容结束位, 闭合围栏位}；无完整对象
      # 返回 {nil, 0, 0}。
      # JSON 扫描状态机天然分支密度高（字符串/转义/括号三态），拆分反而
      # 增加状态传递——行内豁免。
      private def self.extract_block(text : String) : Tuple(String?, Int32, Int32) # ameba:disable Metrics/CyclomaticComplexity
        start = text.index("```json")
        return {nil, 0, 0} if start.nil?
        body_start = start + "```json".size
        depth = 0
        in_string = false
        escaped = false
        start_idx = -1
        end_idx = -1
        text.each_char_with_index do |char, pos|
          next if pos < body_start
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
          when '"'  then in_string = true
          when '\\' then escaped = true
          when '{'
            start_idx = pos if depth.zero?
            depth += 1
          when '}'
            depth -= 1
            if depth.zero? && start_idx >= 0
              end_idx = pos
              break
            end
          end
        end
        return {nil, 0, 0} if end_idx < 0
        closing = text.index("```", end_idx + 1)
        return {nil, 0, 0} if closing.nil?
        {text[start_idx..end_idx], end_idx + 1, closing}
      end
    end
  end
end
