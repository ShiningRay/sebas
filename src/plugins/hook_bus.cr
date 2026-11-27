require "json"
require "./hook_dispatcher"

# 宿主子系统侧 hook 门面（M3-WP5，#17）：把 HookDispatcher 包成可空实例——
# plugins.dir 未配置/未装配时注入点零开销直通（nil dispatcher = 空操作），
# 子系统只依赖本门面，不反向依赖 gateway 装配细节。
#
# 预算按 turn 划界（§12.11）：budget_factory 每次派发调用新建一个 Budget——
# 缺省「单次 hook 链即最小 turn」（跨 turn 累计零风险）；宿主需要更宽边界时
# 传入自定义工厂（如按 agent turn 缓存复用同一 Budget 实例）。
module Sebas
  module Plugins
    struct HookBus
      getter dispatcher : HookDispatcher?
      getter budget_factory : -> HookDispatcher::Budget

      def initialize(@dispatcher : HookDispatcher? = nil,
                     budget_factory : -> HookDispatcher::Budget = -> { HookDispatcher::Budget.new })
        @budget_factory = budget_factory
      end

      private def budget_for_call : HookDispatcher::Budget
        @budget_factory.call
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
        d.observe(hook, context, payload, budget: budget_for_call, idempotency_key: idempotency_key) if d
      end

      # gate：无装配即放行（payload 原样）；deny 带结构化 code/reason。
      def gate(hook : String, context : JSON::Any, payload : JSON::Any,
               idempotency_key : String? = nil) : HookDispatcher::Verdict
        d = @dispatcher
        return HookDispatcher::Verdict.allow(payload) unless d
        d.gate(hook, context, payload, budget: budget_for_call, idempotency_key: idempotency_key)
      end

      # transform：无装配即原样；替换后的 payload 已重过 schema 校验。
      def transform(hook : String, context : JSON::Any, payload : JSON::Any,
                    idempotency_key : String? = nil) : HookDispatcher::Verdict
        d = @dispatcher
        return HookDispatcher::Verdict.allow(payload) unless d
        d.transform(hook, context, payload, budget: budget_for_call, idempotency_key: idempotency_key)
      end
    end
  end
end
