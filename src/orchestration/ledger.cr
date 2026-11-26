require "../platform/store/store"
require "../log"

# 账本 + 预算（M2-WP5，design.md §7.4）：
# append-only 事件账本（触发/条件/动作/审批全记入，runs 回放审计口径）；
# 预算记账（per run token 花费），超限熔断拒绝并账本留痕（§14 M2 验收第 3 条）。
# lease 存取在 store 层（lease_acquire/heartbeat/release/reap_expired）。
module Sebas
  module Orchestration
    class Ledger
      Log = Sebas::Log.for("orchestration.ledger")

      getter store : ::Sebas::Platform::Store::Store

      def initialize(@store : ::Sebas::Platform::Store::Store)
      end

      def append(run_id : String, kind : String, payload : String = "") : Nil
        @store.ledger_append(run_id, kind, payload)
      end

      def replay(run_id : String) : Array(::Sebas::Platform::Store::Store::LedgerRow)
        @store.ledger_replay(run_id)
      end
    end

    class Budget
      Log = Sebas::Log.for("orchestration.budget")

      getter limit_tokens : Int64
      getter store : ::Sebas::Platform::Store::Store
      getter ledger : Ledger

      # per-run 已花费（内存记账；run 结束即释放——持久口径在 ledger）
      @spent = Hash(String, Int64).new
      @exceeded = Set(String).new
      @mutex = Mutex.new

      def initialize(@store : ::Sebas::Platform::Store::Store, @ledger : Ledger, @limit_tokens : Int64)
      end

      # 记账：未超限 → true 并累计；超限 → false（熔断拒绝）+ 账本留痕
      def spend(run_id : String, tokens : Int64) : Bool
        @mutex.synchronize do
          current = @spent.fetch(run_id, 0_i64)
          if current + tokens > @limit_tokens || @exceeded.includes?(run_id)
            unless @exceeded.includes?(run_id)
              @exceeded << run_id
              @ledger.append(run_id, "budget.exceeded",
                %({"spent": #{current}, "requested": #{tokens}, "limit": #{@limit_tokens}}))
              Log.warn { "budget exceeded: run=#{run_id} spent=#{current}+#{tokens} > limit=#{@limit_tokens}" }
            end
            return false
          end
          @spent[run_id] = current + tokens
          @ledger.append(run_id, "budget.spend", %({"tokens": #{tokens}, "total": #{current + tokens}}))
          true
        end
      end

      def exceeded?(run_id : String) : Bool
        @mutex.synchronize { @exceeded.includes?(run_id) }
      end

      def spent(run_id : String) : Int64
        @mutex.synchronize { @spent.fetch(run_id, 0_i64) }
      end
    end
  end
end
