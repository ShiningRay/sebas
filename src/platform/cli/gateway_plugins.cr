require "json"
require "digest"
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

        # 插件面装配：返回 false = 装配失败（降级）——工具面/hook 门面全量
        # 停用且热更新结果记降级（M3-WP5 review）。all-or-nothing：全部构件
        # 就绪才换引用，装配中途失败时 @plugin_dispatch/@hook_bus 同步归零，
        # 注入点不出现「hook 新代 + 工具 nil」的混合态。
        # 返回 true 含「plugins.dir 未配置」的正常停用路径。
        private def wire_plugins(config : Config::Config) : Bool
          tools = @tools_registry || (Log.error { "plugins face wired before tool surface build" }; return false)
          # 工具面同步：先摘旧名单再挂新名单（registry.unregister 语义）
          @plugin_tool_names.each { |name| tools.unregister(name) }
          @plugin_tool_names = [] of String
          @plugin_dispatch = nil
          @hook_bus = ::Sebas::Plugins::HookBus.disabled

          dir = config.plugins.dir
          unless dir
            Log.info { "plugins face disabled (no plugins.dir)" }
            return true
          end

          registry = ::Sebas::Plugins::Registry.new
          report = registry.load_dir(Path[dir])
          report.errors.each { |e| Log.error { "plugin load failed: #{e}" } }
          if report.loaded.empty? && !report.errors.empty?
            Log.warn { "plugins face configured but no plugin loaded (dir=#{dir})" }
          end

          interpreter = config.plugins.interpreter || "mruby"
          args = config.plugins.interpreter_args || [] of String
          # 生产装配也承载 OS 配额（M3-WP5 review）：非法值 fail-closed——
          # 局部 rescue 吞掉异常会把「无资源限制」的插件面放行（与注释约定
          # 相反）。重抛给方法级 rescue：plugins face wiring failed → 整面
          # 停用（loader 启动期校验是第一道，此处是热更新路径的第二道）。
          limits = ::Sebas::Plugins::ResourceLimits.from_config(config.plugins.memory_mb,
            config.plugins.cpu_seconds)
          runner = ::Sebas::Plugins::Runner.new([interpreter] + args, limits: limits)
          dispatch = ::Sebas::Plugins::Dispatch.new(registry, runner)

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
          hook_bus = ::Sebas::Plugins::HookBus.new(hook_dispatcher)

          # capability driver 装配（M3-WP5，#17 §12.4 ③ §12.10）：双重白名单
          # 第二关——manifest 声明之外还须宿主登记 driver；受控 memory.backend
          # 提供 remember 写路径并承载 memory.remember 双 hook 注入点
          caps = ::Sebas::Plugins::CapabilityDispatcher.new
          caps.hook_bus = hook_bus
          memory_driver = ::Sebas::Plugins::CapabilityDispatcher::MemoryDriver.new(hook_bus)
          caps.register("memory_driver.write") do |plugin_id, params, context, replay_key|
            # 幂等键派生（M3-WP5 review）：task 重放身份（工具面 idempotency_key
            # 随 Request 透传）+ 写入内容指纹——同 task 同内容重放命中同 key，
            # gate memo 与 write memo 一并复用；无 task 身份（hook 路径）不 memo
            key = replay_key ? "memory_driver.write:#{plugin_id}:#{Digest::SHA256.hexdigest(params.to_json)}" : nil
            memory_driver.write(plugin_id, params, context, idempotency_key: key)
          end
          runner.capability_handler = ->(plugin : ::Sebas::Plugins::LoadedPlugin, capability : String, params : JSON::Any, replay_key : String?) do
            # scope 注入（§12.10）：身份由宿主合成，插件传参仅 params
            caps.dispatch(plugin.id, capability, params,
              JSON.parse(%({"plugin_id": #{plugin.id.inspect}})), replay_key)
          end

          @plugin_dispatch = dispatch
          @plugin_tool_names = dispatch.register_tools_into(tools)
          @hook_bus = hook_bus # 全部就绪才换引用（all-or-nothing）
          Log.info { "plugins loaded: #{report.loaded.join(",")} (tools: #{@plugin_tool_names.size})" }
          true
        rescue ex : ::Exception
          Log.error(exception: ex) { "plugins face wiring failed: #{ex.message}" }
          @plugin_dispatch = nil
          @plugin_tool_names = [] of String
          @hook_bus = ::Sebas::Plugins::HookBus.disabled # 注入点一致：hook 门面随工具面同代停用
          false
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

        def inject_runtime_hooks(runtime : ::Sebas::Agents::AgentRuntime,
                                 hook_bus : ::Sebas::Plugins::HookBus) : Nil
          runtime.hook_bus = hook_bus # agent/llm 域注入（turn 级 Budget 总线由 agent_turn 传入）
        end

        # 归档压缩接线（M3-WP5 review）：CompactionRunner + 缺省 compactor
        # （全量转写拼接摘要——SessionCompactor 接口的完整实现，非假 hook；
        # 生产压缩器后续包替换）。archive 时真实触发 before/after。
        def wire_compaction : Nil
          compactor = CompactionTailCompactor.new
          @lifecycle_store.compaction_runner = ::Sebas::Sessions::Compaction::CompactionRunner.new(@hook_bus)
          @lifecycle_store.session_compactor = compactor
        end

        private def wire_hook_faces : Nil
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

# 缺省压缩器（SessionCompactor 接口完整实现）：全量转写拼接为摘要。
# 生产压缩器（LLM 摘要）后续包替换本实现——接口与协议不变。
class CompactionTailCompactor < ::Sebas::Sessions::Compaction::SessionCompactor
  def compact(session_key : String, transcript : Array(String)) : ::Sebas::Sessions::Compaction::CompactionResult
    summary = transcript.last(50).join("\n")[0, 2000]
    ::Sebas::Sessions::Compaction::CompactionResult.new(
      summary, summary.size, transcript.size - Math.min(transcript.size, 50))
  end
end
