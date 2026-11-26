require "../../src/agents/agents"
require "../../src/channels/registry"
require "../../src/orchestration/collaboration/collaboration"
require "../../src/tools/executor"

# 装配层同径构造（#185 WP1）：默认工具面 → 协作工具注册 → 白名单裁剪 → 真实
# Executor。与 GatewayDispatch#attenuated_registry 同序同口径，spec 不绕过装配层。
# 共用 helper（CodeRabbit）：两个 spec 文件 require 本文件，避免跨文件顶层依赖。
def collab_tool_face(messenger, allowed : Array(String))
  channels = ::Sebas::Channels::Registry.new
  registry = ::Sebas::Tools.default_registry(channels)
  ::Sebas::Orchestration::Collaboration.register_tool_face(registry, messenger)
  registry.restrict_to(allowed)
  {::Sebas::Tools::Executor.new(registry, channels), registry, channels}
end
