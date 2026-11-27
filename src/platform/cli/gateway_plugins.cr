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

        # hook 门面（M3-WP5，#17）：gateway.start/stop 及各子系统注入点共用
        @hook_bus : ::Sebas::Plugins::HookBus = ::Sebas::Plugins::HookBus.disabled

        private def wire_plugins(config : Config::Config) : Nil
          tools = @tools_registry || (Log.error { "plugins face wired before tool surface build" }; return)
          # 工具面同步：先摘旧名单再挂新名单（registry.unregister 语义）
          @plugin_tool_names.each { |name| tools.unregister(name) }
          @plugin_tool_names = [] of String
          @plugin_dispatch = nil
          @hook_bus = ::Sebas::Plugins::HookBus.disabled

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

          # hook 订阅链装配（M3-WP5，#17）：逐插件逐 hook 订阅；敏感批准缺失/
          # 重复/未知钩子按单插件单订阅 fail-logged 跳过，不炸 gateway 装配
          hook_dispatcher = ::Sebas::Plugins::HookDispatcher.new
          hook_dispatcher.dispatch = dispatch
          registry.ids.each do |id|
            plugin = registry.plugin(id)
            next unless plugin
            plugin.manifest.hooks_list.each do |hook|
              # ameba:disable Style/RedundantBegin — 块内 inline rescue 必须显式 begin
              begin
                hook_dispatcher.subscribe(hook, plugin.manifest, id)
              rescue ex
                Log.error { "hook subscription rejected: plugin=#{id} hook=#{hook} (#{ex.message})" }
              end
            end
          end
          @hook_bus = ::Sebas::Plugins::HookBus.new(hook_dispatcher)

          # capability driver 装配（M3-WP5，#17 §12.4 ③ §12.10）：双重白名单
          # 第二关——manifest 声明之外还须宿主登记 driver；受控 memory.backend
          # 提供 remember 写路径并承载 memory.remember 双 hook 注入点
          caps = ::Sebas::Plugins::CapabilityDispatcher.new
          caps.hook_bus = @hook_bus
          memory_driver = ::Sebas::Plugins::CapabilityDispatcher::MemoryDriver.new(@hook_bus)
          caps.register("memory_driver.write") do |plugin_id, params, context|
            memory_driver.write(plugin_id, params, context)
          end
          runner.capability_handler = ->(plugin : ::Sebas::Plugins::LoadedPlugin, capability : String, params : JSON::Any) do
            # scope 注入（§12.10）：身份由宿主合成，插件传参仅 params
            caps.dispatch(plugin.id, capability, params,
              JSON.parse(%({"plugin_id": #{plugin.id.inspect}})))
          end
          Log.info { "plugins loaded: #{report.loaded.join(",")} (tools: #{@plugin_tool_names.size})" }
        rescue ex : ::Exception
          Log.error(exception: ex) { "plugins face wiring failed: #{ex.message}" }
          @plugin_dispatch = nil
          @plugin_tool_names = [] of String
        end

        # gateway 生命周期 hook 触发（M3-WP5，#17）：单行门面，保 gateway.cr
        # 400 行体量闸（GatewayDispatch 拆分回归 spec）
        def fire_gateway_start : Nil
          @hook_bus.observe("gateway.start", JSON.parse("{}"), JSON.parse("{}"))
        end

        def fire_gateway_stop : Nil
          @hook_bus.observe("gateway.stop", JSON.parse("{}"), JSON.parse("{}"))
        end

        # message.received（渠道验真/去重/解析完成后、路由前 observe）
        def observe_message_received(message : ::Sebas::Platform::Bus::InboundMessage) : Nil
          received = JSON.parse(JSON.build do |json|
            json.object do
              json.field "channel", message.channel_type
              json.field "account_id", message.account_id
              json.field "peer", message.peer
              json.field "message_id", message.event_id
              json.field "size", message.content.bytesize
            end
          end)
          @hook_bus.observe("message.received", JSON.parse("{}"), received)
        end

        def inject_runtime_hooks(runtime : ::Sebas::Agents::AgentRuntime) : Nil
          runtime.hook_bus = @hook_bus # agent/llm 域注入
        end

        def wire_hook_faces : Nil
          @executor.hook_bus = @hook_bus        # 工具域注入
          @lifecycle_store.hook_bus = @hook_bus # session 域注入
          if send_tool = @tools_registry.find("message.send").as?(Tools::MessageSendTool)
            send_tool.hook_bus = @hook_bus # 消息域注入
          end
        end
      end
    end
  end
end
