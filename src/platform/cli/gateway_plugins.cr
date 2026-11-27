require "json"
require "../../log"
require "../../plugins/manifest"
require "../../plugins/registry"
require "../../plugins/runner"
require "../../plugins/dispatch"

# 插件面装配（M3-WP4，#16；design.md §12）：gateway 启动/热更新时扫描
# plugins.dir，runner+派发接线，非生命周期 action 注册进宿主工具面
# （plugin.<id>.<action>），agent 经既有审批/衰减链调用。
#
# 热更新语义（数据类）：每动作新进程——目录内容即生效内容，无需 restart；
# manifest 缓存重扫同步，工具面按名单同步增删。
# capability driver 未装配（WP4 无生产 driver；WP5 接受控 memory.backend
# 与 scope 注入），插件调 capability 得结构化 capability_driver_missing。
module Sebas
  module Platform
    module CLI
      module GatewayPlugins
        Log = Sebas::Log.for("gateway")

        # 插件面 ivar（M3-WP4，#16）：dir 未配置 = 关闭（dispatch nil、工具面空）
        @plugin_dispatch : ::Sebas::Plugins::Dispatch? = nil
        @plugin_tool_names : Array(String) = [] of String

        private def wire_plugins(config : Config::Config) : Nil
          tools = @tools_registry || (Log.error { "plugins face wired before tool surface build" }; return)
          # 工具面同步：先摘旧名单再挂新名单（registry.unregister 语义）
          @plugin_tool_names.each { |name| tools.unregister(name) }
          @plugin_tool_names = [] of String
          @plugin_dispatch = nil

          dir = config.plugins.dir
          unless dir
            Log.info { "plugins face disabled (no plugins.dir)" }
            return
          end

          registry = ::Sebas::Plugins::Registry.new
          report = registry.load_dir(Path[dir])
          report.errors.each { |e| Log.error { "plugin load failed: #{e}" } }
          if report.loaded.empty? && !report.errors.empty?
            Log.warn { "plugins face configured but no plugin loaded (dir=#{dir})" }
          end

          interpreter = config.plugins.interpreter || "mruby"
          args = config.plugins.interpreter_args || [] of String
          runner = ::Sebas::Plugins::Runner.new([interpreter] + args)
          dispatch = ::Sebas::Plugins::Dispatch.new(registry, runner)
          @plugin_dispatch = dispatch
          @plugin_tool_names = dispatch.register_tools_into(tools)
          Log.info { "plugins loaded: #{report.loaded.join(",")} (tools: #{@plugin_tool_names.size})" }
        rescue ex : ::Exception
          Log.error(exception: ex) { "plugins face wiring failed: #{ex.message}" }
          @plugin_dispatch = nil
          @plugin_tool_names = [] of String
        end
      end
    end
  end
end
