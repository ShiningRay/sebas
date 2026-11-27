require "json"
require "./hook_dispatcher"

# 宿主子系统侧 hook 门面（M3-WP5，#17）：把 HookDispatcher 包成可空实例——
# plugins.dir 未配置/未装配时注入点零开销直通（nil dispatcher = 空操作），
# 子系统只依赖本门面，不反向依赖 gateway 装配细节。
#
# 预算按 turn 划界：宿主在每个 turn/调用入口建一个 Budget 实例传入；
# 本门面默认共享单一 Budget（gateway 装配时给定上限），跨 turn 复用——
# 这是 §12.11「每 turn 次数/深度/总耗时上限」的保守实现：以 gateway 生命周期
# 为大 turn，per-turn 精确划界随逐域接入补齐。
module Sebas
  module Plugins
    struct HookBus
      getter dispatcher : HookDispatcher?
      getter budget : HookDispatcher::Budget

      def initialize(@dispatcher : HookDispatcher? = nil, budget : HookDispatcher::Budget? = nil)
        @budget = budget || HookDispatcher::Budget.new
      end

      def self.disabled : HookBus
        new(nil)
      end

      def enabled? : Bool
        !@dispatcher.nil?
      end

      # observe：无装配即 no-op；payload 契约违约由 dispatcher 记日志跳过。
      def observe(hook : String, context : JSON::Any, payload : JSON::Any,
                  idempotency_key : String? = nil) : Nil
        d = @dispatcher
        d.observe(hook, context, payload, budget: @budget, idempotency_key: idempotency_key) if d
      end

      # gate：无装配即放行（payload 原样）；deny 带结构化 code/reason。
      def gate(hook : String, context : JSON::Any, payload : JSON::Any,
               idempotency_key : String? = nil) : HookDispatcher::Verdict
        d = @dispatcher
        return HookDispatcher::Verdict.allow(payload) unless d
        d.gate(hook, context, payload, budget: @budget, idempotency_key: idempotency_key)
      end

      # transform：无装配即原样；替换后的 payload 已重过 schema 校验。
      def transform(hook : String, context : JSON::Any, payload : JSON::Any,
                    idempotency_key : String? = nil) : HookDispatcher::Verdict
        d = @dispatcher
        return HookDispatcher::Verdict.allow(payload) unless d
        d.transform(hook, context, payload, budget: @budget, idempotency_key: idempotency_key)
      end
    end
  end
end
