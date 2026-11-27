require "json"
require "./hooks"
require "./runner"
require "./dispatch"

# 钩子派发语义（M3-WP5，#17；design.md §12.11 统一执行规则）。
#
# - gate/transform 同步按序执行，每个处理器接收上一个已校验结果；任一 deny
#   停止后续处理器。异常、超时、非法结果默认 deny（fail-closed）；
# - observe 按注册快照执行、忽略返回值，异常记录脱敏日志并跳过，不阻塞主流程；
# - 处理器返回值口径：deny 用 {"verdict"=>"deny","code"…,"reason"…} 或 DSL
#   deny!（结构化错误 code=hook_deny）；transform 直接返回替换后的 payload
#   （裸值），宿主重新过同一 payload schema 校验（§12.11「宿主再次解析和
#   校验」），替换非法按 deny fail-closed；
# - 排序：priority 数值大者优先，再按插件 ID 稳定排序（§12.11）；
# - 预算：每 turn 的调用次数/深度/总耗时上限（Budget），超限 gate/transform
#   判 deny、observe 跳过；
# - memo：可重放 hook（带 idempotency_key）的决策持久化——同 key 直接复用
#   上次裁决，不重复执行插件（task/重放语义 §12.11）。
#
# 宿主注入点在各子系统（tools/providers/channels/agents/sessions/store/
# orchestration/gateway 生命周期），经本派发器调用；plugins.dir 未配置时
# 宿主侧装配为 nil，注入点零开销直通。
module Sebas
  module Plugins
    class HookDispatcher
      Log = Hooks::Log

      record Subscription, plugin_id : String, priority : Int64

      # 单条 hook 处理链的裁决。deny 携带结构化 code/reason；payload 仅在
      # transform 替换成功时携带（已重过 schema 校验）。
      record Verdict,
        denied : Bool,
        code : String?,
        reason : String?,
        payload : JSON::Any? do
        def self.allow(payload : JSON::Any? = nil) : Verdict
          new(false, nil, nil, payload)
        end

        def self.deny(code : String, reason : String) : Verdict
          new(true, code, reason, nil)
        end
      end

      class BudgetExceededError < RuntimeError; end

      # 每 turn 预算：调用次数上限、深度上限、总耗时上限。复用方每 turn
      # 建一个 Budget 实例传入 dispatch_*；nil 表示不设预算（测试/装配前）。
      class Budget
        property calls : Int32 = 0
        property total_ms : Int64 = 0
        getter max_calls : Int32
        getter max_depth : Int32
        getter max_total_ms : Int64

        def initialize(max_calls : Int32 = 256, max_depth : Int32 = 4, max_total_ms : Int64 = 2000)
          @max_calls = max_calls
          @max_depth = max_depth
          @max_total_ms = max_total_ms
        end

        def exceeded? : Bool
          @calls >= @max_calls || @total_ms >= @max_total_ms
        end
      end

      # 可重放 hook 的决策 memo（§12.11）：键 idempotency_key，值裁决。
      # 内存实现承载 WP5 语义；持久化由宿主 store 在后续包接入时替换。
      class Memo
        @store = Hash(String, Verdict).new
        @mutex = Mutex.new

        def fetch(key : String?) : Verdict?
          if key.nil?
            nil
          else
            @mutex.synchronize { @store[key]? }
          end
        end

        def record(key : String?, verdict : Verdict) : Nil
          return unless key
          @mutex.synchronize { @store[key] = verdict }
        end
      end

      getter subscriptions : Hash(String, Array(Subscription))
      getter memo : Memo

      @depth = Atomic(Int32).new(0)

      def initialize
        @subscriptions = Hash(String, Array(Subscription)).new
        @mutex = Mutex.new
        @memo = Memo.new
      end

      # 订阅：名称必须在 22 hook 闭集内；敏感 hook 要求插件 manifest 显式
      # 声明 hooks.sensitive capability（§12.11 单独批准）；同插件重复注册
      # 同一 hook 拒绝（§12.11）。
      def subscribe(hook : String, manifest : Manifest, plugin_id : String = manifest.id) : Nil
        defn = Hooks.definition!(hook) # 未知钩子： raise SchemaError
        if defn.sensitive && !manifest.declares_capability?(Hooks::SENSITIVE_CAPABILITY)
          raise Hooks::SchemaError.new(
            "plugin #{plugin_id} subscribes sensitive hook '#{hook}' without capability #{Hooks::SENSITIVE_CAPABILITY}")
        end
        @mutex.synchronize do
          subs = (@subscriptions[hook] ||= [] of Subscription)
          if subs.any?(&.plugin_id.==(plugin_id))
            raise Hooks::SchemaError.new("plugin #{plugin_id} already subscribes hook '#{hook}'")
          end
          subs << Subscription.new(plugin_id, manifest.hook_priority(hook))
          # priority 大者优先，再按插件 ID 稳定排序（§12.11）
          subs.sort_by! { |sub| {-sub.priority, sub.plugin_id} }
        end
      end

      def subscribers(hook : String) : Array(Subscription)
        @mutex.synchronize { (@subscriptions[hook]? || [] of Subscription).dup }
      end

      # observe：按注册快照逐个派发，忽略返回值；任何失败（插件错误/超时/
      # payload 非法/预算超限）记脱敏日志并跳过，绝不阻塞主流程。
      def observe(hook : String, context : JSON::Any, payload : JSON::Any,
                  budget : Budget? = nil, idempotency_key : String? = nil) : Nil
        defn = Hooks.definition!(hook)
        return unless defn.kind.observe?
        begin
          Hooks.validate_payload!(hook, payload)
        rescue ex : Hooks::SchemaError
          Log.warn { "observe hook #{hook} skipped: #{ex.message} (payload contract violation)" }
          return
        end
        each_subscriber(hook, budget) do |sub|
          outcome = call_plugin(hook, context, payload, sub, idempotency_key, budget)
          unless outcome.ok
            Log.warn { "observe hook #{hook} skipped: plugin=#{sub.plugin_id} code=#{outcome.error_code} (failure isolated)" }
          end
        end
      end

      # gate：同步链逐个判定；deny（显式 deny、异常/超时、非法结果、预算
      # 超限、payload 非法）立即返回，不执行后续处理器。
      def gate(hook : String, context : JSON::Any, payload : JSON::Any,
               budget : Budget? = nil, idempotency_key : String? = nil) : Verdict
        defn = Hooks.definition!(hook)
        unless defn.kind.gate? || defn.kind.gate_transform?
          raise Hooks::SchemaError.new("hook #{hook} is not a gate")
        end
        memo_hit = memo.fetch(idempotency_key)
        return memo_hit if memo_hit
        denial = payload_denial(hook, payload)
        return denial if denial
        if budget && budget.exceeded?
          return record_denied(hook, idempotency_key, "hook_budget_exceeded",
            "hook budget exceeded (calls=#{budget.calls} total_ms=#{budget.total_ms})")
        end

        current = payload
        each_subscriber(hook, budget) do |sub|
          outcome = call_plugin(hook, context, current, sub, idempotency_key, budget)
          verdict = interpret(hook, sub, outcome, current, transformable: false)
          if verdict.denied
            return record_denied(hook, idempotency_key, verdict.code || "denied", verdict.reason || "denied")
          end
          current = verdict.payload || current
        end
        verdict = Verdict.allow(current)
        memo.record(idempotency_key, verdict)
        verdict
      end

      # transform：同步链逐个替换 payload；裸返回值即替换（重过 schema），
      # 非法替换/异常/超时按 deny fail-closed。
      def transform(hook : String, context : JSON::Any, payload : JSON::Any,
                    budget : Budget? = nil, idempotency_key : String? = nil) : Verdict
        defn = Hooks.definition!(hook)
        unless defn.kind.transform? || defn.kind.gate_transform?
          raise Hooks::SchemaError.new("hook #{hook} is not a transform")
        end
        memo_hit = memo.fetch(idempotency_key)
        return memo_hit if memo_hit
        denial = payload_denial(hook, payload)
        return denial if denial
        if budget && budget.exceeded?
          return record_denied(hook, idempotency_key, "hook_budget_exceeded",
            "hook budget exceeded (calls=#{budget.calls} total_ms=#{budget.total_ms})")
        end

        current = payload
        each_subscriber(hook, budget) do |sub|
          outcome = call_plugin(hook, context, current, sub, idempotency_key, budget)
          verdict = interpret(hook, sub, outcome, current, transformable: true)
          if verdict.denied
            return record_denied(hook, idempotency_key, verdict.code || "denied", verdict.reason || "denied")
          end
          current = verdict.payload || current
        end
        verdict = Verdict.allow(current)
        memo.record(idempotency_key, verdict)
        verdict
      end

      private def record_denied(hook : String, key : String?, code : String, reason : String) : Verdict
        verdict = Verdict.deny(code, reason)
        memo.record(key, verdict)
        Log.warn { "hook #{hook} denied: code=#{code} reason=#{reason[0, 120]}" }
        verdict
      end

      private def payload_denial(hook : String, payload : JSON::Any) : Verdict?
        Hooks.validate_payload!(hook, payload)
        nil
      rescue ex : Hooks::SchemaError
        record_denied(hook, nil, "invalid_payload", ex.message || "invalid payload")
      end

      # 处理器裁决解释（§12.11 gate/transform 非法结果默认 deny）：
      # - deny：{"verdict"=>"deny","code"…,"reason"…} 或 deny! 的结构化错误
      #   （code=hook_deny），其余 error/timeout 一律 deny；
      # - gate：ok 非 deny 即 allow（gate_transform 允许 {"verdict"=>"allow",
      #   "payload"…} 携带替换）；
      # - transform：裸 JSON-like 返回值即替换 payload，重过 schema 校验，
      #   替换非法 deny。
      # ameba:disable Metrics/CyclomaticComplexity — 裁决解释状态机，分支即语义
      private def interpret(hook : String, sub : Subscription, outcome : CallOutcome,
                            current : JSON::Any, transformable : Bool) : Verdict
        if outcome.ok
          value = outcome.value
          if table = value.try(&.as_h?)
            case table["verdict"]?.try(&.as_s?)
            when "deny"
              return Verdict.deny(table["code"]?.try(&.as_s?) || "plugin_deny",
                table["reason"]?.try(&.as_s?) || "denied by #{sub.plugin_id}")
            when "allow"
              replacement = table["payload"]?
              return Verdict.allow(current) if replacement.nil?
              return revalidated(hook, sub, replacement) || Verdict.allow(current)
            end
          end
          if transformable && value && !value.as_h?.nil?
            # 裸返回值 = 替换后的 payload（DSL modify 语义），宿主重新校验
            replacement = JSON::Any.new(value.raw)
            revalidated(hook, sub, replacement) || Verdict.allow(current)
          else
            Verdict.allow(current)
          end
        elsif outcome.error_code == "hook_deny"
          Verdict.deny("plugin_deny", outcome.error_message || "denied by #{sub.plugin_id}")
        else
          Verdict.deny(outcome.error_code || "hook_failed",
            (outcome.error_message || "hook failed")[0, 200])
        end
      end

      # 替换 payload 重过 payload schema（§12.11：宿主重新校验）；非法替换
      # deny fail-closed。
      private def revalidated(hook : String, sub : Subscription, replacement : JSON::Any) : Verdict?
        Hooks.validate_payload!(hook, replacement)
        Verdict.allow(replacement)
      rescue ex : Hooks::SchemaError
        Verdict.deny("invalid_result",
          "replacement payload rejected: #{ex.message} (plugin #{sub.plugin_id})")
      end

      private def call_plugin(hook : String, context : JSON::Any, payload : JSON::Any,
                              sub : Subscription, idempotency_key : String?,
                              budget : Budget?) : CallOutcome
        if budget
          raise BudgetExceededError.new("hook budget exceeded (calls=#{budget.calls})") if budget.exceeded?
          budget.calls += 1
        end
        depth = @depth.add(1)
        if budget && depth > budget.max_depth
          @depth.add(-1)
          return CallOutcome.error("hook_depth_exceeded", "hook recursion depth #{depth} exceeds budget", 0)
        end
        begin
          dispatch = @dispatch
          unless dispatch
            return CallOutcome.error("hook_dispatch_missing", "plugin dispatch not assembled", 0)
          end
          started = Time.instant
          outcome = dispatch.call_plugin_for_hook(sub.plugin_id, hook, context, payload, idempotency_key)
          if budget
            budget.total_ms += (Time.instant - started).total_milliseconds.to_i64
          end
          outcome
        ensure
          @depth.add(-1)
        end
      end

      setter dispatch : Dispatch?

      # 预算超限在 gate/transform 路径表现为 deny、observe 路径为跳过：
      # 统一在订阅循环外层把 BudgetExceededError 折算成剩余订阅者跳过。
      private def each_subscriber(hook : String, budget : Budget?, &)
        return if budget && budget.exceeded?
        subscribers(hook).each do |sub|
          # ameba:disable Style/RedundantBegin — 块内 inline rescue 必须显式 begin
          begin
            yield sub
          rescue BudgetExceededError
            Log.warn { "hook #{hook} budget exceeded; remaining subscribers skipped" }
            return
          end
        end
      end
    end
  end
end
