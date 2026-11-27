require "json"
require "./manifest"
require "./protocol"
require "./registry"
require "./runner"

# 精确派发服务（M3-WP4，#16；design.md §12.2）：宿主侧的派发闸。
#
# - 只派发 manifest 声明的 action/hook（未声明 = 越权，宿主直接拒绝，
#   不 spawn 解释器）；「本次进程内已注册」由 prelude 报告 + runner 校验；
# - hook 按 manifest 订阅索引精确派发到声明插件，不群发；
# - install/enable/disable 生命周期动作只经显式 call_action 调用——hook
#   派发路径永远不触达它们（§12.3 无隐式 init）。
module Sebas
  module Plugins
    class Dispatch
      getter registry : Registry
      getter runner : Runner

      # 插件配置真相源占位（WP6 接 plugin-config/<id>.yaml；当前固定空对象）
      setter config_provider : (String -> JSON::Any)?

      def initialize(@registry : Registry, @runner : Runner)
      end

      # 显式动作调用（工具面与生命周期动作共用入口；生命周期动作不可被
      # hook 派发路径触达——call_hook 从不经过这里）。
      def call_action(plugin_id : String, action : String, context : JSON::Any,
                      payload : JSON::Any, idempotency_key : String? = nil) : CallOutcome
        plugin = registry.plugin(plugin_id)
        return plugin_missing(plugin_id, action) unless plugin
        unless plugin.manifest.declares_action?(action)
          return CallOutcome.error("action_not_declared",
            "plugin #{plugin_id} does not declare action '#{action}' in manifest", 0)
        end
        runner.call(plugin, Protocol::Request.new(
          request_id: Random::Secure.hex(8),
          plugin_id: plugin_id,
          action: action,
          context: context,
          payload: payload,
          config: config_for(plugin_id),
          idempotency_key: idempotency_key,
        ))
      rescue ex : RunnerError
        # 装配类错误（解释器缺失等）：响亮上抛给调用方，不伪装成插件结果
        raise ex
      rescue ex : ::Exception
        CallOutcome.error("dispatch_failed", (ex.message || "dispatch failed")[0, 500], 0)
      end

      # hook 精确派发：只遍历 manifest 声明该 hook 的订阅插件（不群发）。
      # 生命周期动作名不会出现在这里——hook 名域与 action 名域正交。
      def call_hook(hook : String, context : JSON::Any, payload : JSON::Any) : Array(Tuple(String, CallOutcome))
        outcomes = [] of Tuple(String, CallOutcome)
        registry.subscribers_for_hook(hook).each do |plugin|
          outcome = runner.call(plugin, Protocol::Request.new(
            request_id: Random::Secure.hex(8),
            plugin_id: plugin.id,
            action: hook,
            context: context,
            payload: payload,
            config: config_for(plugin.id),
            idempotency_key: nil,
          ))
          outcomes << {plugin.id, outcome}
        end
        outcomes
      end

      # gateway 工具装配：manifest.tool_actions（生命周期动作除外）逐个
      # 注册为 plugin.<id>.<action> 工具（§12.10：默认 risk high、不可重放）。
      def register_tools_into(tool_registry : ::Sebas::Tools::Registry) : Array(String)
        registered = [] of String
        registry.ids.each do |id|
          plugin = registry.plugin(id) || next
          plugin.manifest.tool_actions.each do |action|
            tool_registry.register(PluginTool.new(self, plugin, action))
            registered << PluginTool.tool_name(id, action)
          end
        end
        registered
      end

      private def config_for(plugin_id : String) : JSON::Any
        provider = @config_provider
        return JSON::Any.new({} of String => JSON::Any) unless provider
        provider.call(plugin_id)
      rescue ::Exception
        JSON::Any.new({} of String => JSON::Any)
      end

      private def plugin_missing(plugin_id : String, action : String) : CallOutcome
        CallOutcome.error("plugin_not_found",
          "plugin #{plugin_id} is not loaded (action '#{action}' not dispatchable)", 0)
      end
    end
  end
end
