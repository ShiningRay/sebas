require "json"
require "../tools/registry"
require "./dispatch"

# 插件工具桥（M3-WP4，#16；design.md §12.10）：插件 action 以
# plugin.<id>.<action> 注册进宿主工具面，agent 经既有 Tools::Executor
# 调用（审批链/衰减/台账口径与内置工具一致）。
#
# 默认档保守（§12.10「默认 risk: high，插件不能自行降低风险」）：
# risk high / replay Effectful / side_effect NetWrite；manifest 级
# risk/replay 声明归 M3-WP5/WP6 接管。
module Sebas
  module Plugins
    class PluginTool < ::Sebas::Tools::Tool
      getter plugin_id : String
      getter action : String

      def self.tool_name(plugin_id : String, action : String) : String
        "plugin.#{plugin_id}.#{action}"
      end

      def initialize(@dispatch : Dispatch, plugin : LoadedPlugin, @action : String)
        @plugin_id = plugin.id
        super(self.class.tool_name(plugin.id, @action),
          "Plugin #{@plugin_id} action '#{@action}' (sandboxed mruby subprocess)",
          ::Sebas::Tools::ReplaySemantics::Effectful,
          ::Sebas::Tools::Risk::High,
          ::Sebas::Tools::SideEffect::NetWrite)
      end

      def run(args : JSON::Any, ctx : ::Sebas::Tools::ToolContext) : ::Sebas::Tools::ToolResult
        # 会话/账号 scope 由宿主注入（§12.2：插件不能传任意 scope）
        context = JSON::Any.new({
          "session_key" => JSON::Any.new(ctx.session_key),
          "account_id"  => JSON::Any.new(ctx.account_id),
          "event_id"    => JSON::Any.new(ctx.event_id),
        } of String => JSON::Any)
        idempotency_key = args.as_h?.try(&.[]?("idempotency_key")).try(&.as_s?)
        outcome = @dispatch.call_action(@plugin_id, @action, context, args, idempotency_key)
        if outcome.ok
          ::Sebas::Tools::ToolResult.success(summarize(outcome))
        else
          ::Sebas::Tools::ToolResult.error("[#{outcome.error_code}] #{outcome.error_message}")
        end
      end

      # 结果摘要：结构化值压缩为受限文本（脱敏纪律与内置工具一致——完整
      # 结构经 to_json 截断，调用方可从账本/日志拿到可诊断摘要）。
      private def summarize(outcome : CallOutcome) : String
        value = outcome.value
        text = value ? value.to_json : "null"
        text.size > 512 ? text[0, 512] + "…(truncated)" : text
      end
    end
  end
end
