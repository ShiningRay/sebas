require "spec"
require "file_utils"
require "../support/plugins_spec_helper"

# agent 调用面验收（M3-WP4，#16）：插件 action 注册进宿主工具面，经
# Tools::Executor（agent 既有工具链：审批/衰减/台账同口径）调用。
interp = PluginSpecSupport.interpreter

module Sebas
  describe "plugin tool bridge（M3-WP4）" do
    it "示例插件工具经 Executor 可被 agent 调用（plugin.<id>.<action>）" do
      unless interp
        pending "需要解释器"
        next
      end
      dispatch = PluginSpecSupport.make_dispatch(interp.as(Array(String)))
      registry = ::Sebas::Tools.default_registry(::Sebas::Channels::Registry.new)
      registered = dispatch.register_tools_into(registry)
      registered.should contain("plugin.echo.ping")
      # 生命周期动作不进工具面（§12.3）
      registered.any?(&.starts_with?("plugin.hooky.")).should be_false

      store = PluginSpecSupport.spec_store
      executor = ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new)
      ctx = ::Sebas::Tools::ToolContext.new(
        session_key: "agent:main:acc:email:peer", account_id: "acc", event_id: "evt", store: store)
      result = executor.run("plugin.echo.ping", JSON.parse(%({"msg":"via-agent"})), ctx)
      result.ok?.should be_true
      result.output.should contain("via-agent")
      store.close
    end

    it "工具执行失败转 ToolResult.error（结构化错误码随文本返回）" do
      unless interp
        pending "需要解释器"
        next
      end
      dispatch = PluginSpecSupport.make_dispatch(interp.as(Array(String)))
      registry = ::Sebas::Tools.default_registry(::Sebas::Channels::Registry.new)
      dispatch.register_tools_into(registry)
      store = PluginSpecSupport.spec_store
      executor = ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new)
      ctx = ::Sebas::Tools::ToolContext.new(
        session_key: "agent:main:acc:email:peer", account_id: "acc", event_id: "evt", store: store)
      result = executor.run("plugin.echo.ping", JSON.parse(%({"cap":"test.fail"})), ctx)
      result.ok?.should be_false
      result.error.to_s.should contain("capability_failed")
      store.close
    end

    it "未知插件工具按 unknown tool 处理（不逃逸）" do
      executor = ::Sebas::Tools::Executor.new(::Sebas::Tools.default_registry(::Sebas::Channels::Registry.new),
        ::Sebas::Channels::Registry.new)
      store = PluginSpecSupport.spec_store
      ctx = ::Sebas::Tools::ToolContext.new(
        session_key: "s", account_id: "a", event_id: "e", store: store)
      result = executor.run("plugin.ghost.ping", JSON.parse("{}"), ctx)
      result.ok?.should be_false
      result.error.to_s.should contain("unknown tool")
      store.close
    end
  end
end
