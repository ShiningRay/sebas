require "json"
require "../platform/store/store"
require "../channels/base"

# 工具注册表（M0-WP6，A9 升级）：replay/risk 为类型级字段（design.md §7.3/§10.3）；
# 决策级幂等走 memo（first-write-wins）；日志全程脱敏（A9）。
module Sebas
  module Tools
    Log = Sebas::Log.for("sebas.tools")

    # 重放语义（Pi §4 二分）：只读/整文件写=Safe 可重跑；未标注一律 Effectful 不重跑
    enum ReplaySemantics
      Safe
      Effectful
    end

    # 风险级别（§10.3 审批链分层；M0 不接审批，M2-WP4 消费）
    enum Risk
      Low
      Medium
      High
    end

    record ToolResult, ok : Bool, output : String, error : String? do
      def self.success(output : String) : ToolResult
        new(true, output, nil)
      end

      def ok? : Bool
        ok
      end

      def self.error(message : String) : ToolResult
        new(false, "", message)
      end

      # 上次运行被中断、状态未知——不重跑，交上层决策（fail-closed）
      def self.interrupted(message : String) : ToolResult
        new(false, "", "interrupted: #{message}")
      end
    end

    # 工具运行上下文：会话/账号维度 + 持久层句柄（scope 由构造器保证，Hermes contextvar 教训反面）
    record ToolContext,
      session_key : String,
      account_id : String,
      event_id : String,
      store : Platform::Store::Store

    abstract class Tool
      getter name : String
      getter description : String
      getter replay : ReplaySemantics
      getter risk : Risk

      def initialize(@name : String, @description : String, @replay : ReplaySemantics, @risk : Risk)
      end

      abstract def run(args : JSON::Any, ctx : ToolContext) : ToolResult
    end

    class Registry
      @tools = Hash(String, Tool).new
      @mutex = Mutex.new

      def register(tool : Tool) : Nil
        @mutex.synchronize { @tools[tool.name] = tool }
      end

      def find(name : String) : Tool?
        @mutex.synchronize { @tools[name]? }
      end

      def names : Array(String)
        @mutex.synchronize { @tools.keys }
      end

      # 工具面描述（进 agent system prompt；M0-WP6b skills 同款输出格式）
      def describe : String
        @mutex.synchronize do
          @tools.values.map { |tool| "- #{tool.name} (risk:#{tool.risk} replay:#{tool.replay}): #{tool.description}" }.join("\n")
        end
      end

      # 日志脱敏（A9）：args 中的敏感字段值替换为 [REDACTED]
      def self.redact(args : JSON::Any) : String
        obj = args.as_h?
        return args.to_s unless obj
        cleaned = obj.map do |key, value|
          value = JSON::Any.new("[REDACTED]") if SENSITIVE_KEYS.includes?(key.downcase)
          {key, value}
        end.to_h
        JSON::Any.new(cleaned).to_json
      rescue ::Exception
        "[UNPARSABLE]"
      end

      SENSITIVE_KEYS = %w[password secret token api_key refresh_token]
    end
  end
end
