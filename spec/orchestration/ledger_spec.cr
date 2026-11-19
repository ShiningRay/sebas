require "spec"
require "file_utils"
require "../../src/orchestration/ledger"
require "../../src/platform/store/store"

def ledger_tmp_store
  dir = Path[Dir.tempdir, "sebas-ledger-spec", Random::Secure.hex(4)]
  FileUtils.rm_rf(dir)
  ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
end

module Sebas
  describe "ledger + budget + lease (M2-WP5)" do
    it "appends events in order and replays them (append-only 账本)" do
      store = ledger_tmp_store
      ledger = ::Sebas::Orchestration::Ledger.new(store)
      ledger.append("run:wf:1", "trigger", %({"source": "hooks/wake"}))
      ledger.append("run:wf:1", "action.start", %({"id": "a0"}))
      ledger.append("run:wf:1", "action.done", %({"id": "a0"}))
      ledger.append("run:other:2", "trigger", "{}") # 其他 run 不串

      events = ledger.replay("run:wf:1")
      events.size.should eq(3)
      events.map(&.kind).should eq(["trigger", "action.start", "action.done"])
      # 事件序与 id 单调（审计回放口径）
      ids = events.map(&.id)
      ids.should eq(ids.sort)
      ledger.replay("run:other:2").size.should eq(1)
      store.close
    end

    it "tripps the budget and records the trip in the ledger (§14 M2 验收第 3 条 预算熔断)" do
      store = ledger_tmp_store
      ledger = ::Sebas::Orchestration::Ledger.new(store)
      budget = ::Sebas::Orchestration::Budget.new(store, ledger, limit_tokens: 100)

      budget.spend("run:b1", 60).should be_true  # 60/100
      budget.spend("run:b1", 30).should be_true  # 90/100
      budget.spend("run:b1", 20).should be_false # 110 > 100 → 熔断拒绝
      budget.exceeded?("run:b1").should be_true
      # 账本留痕
      events = ledger.replay("run:b1")
      events.any? { |e| e.kind == "budget.exceeded" }.should be_true
      # 其他 run 不受影响
      budget.spend("run:b2", 10).should be_true
      store.close
    end

    it "acquires leases with expiry, heartbeats, and reaps expired (lease 回收)" do
      store = ledger_tmp_store
      # 注入时钟的 lease 用真时钟 + 短 ttl 口径
      store.lease_acquire("task-1", "worker-a", ttl: 5.seconds).should be_true
      store.lease_acquire("task-1", "worker-b", ttl: 5.seconds).should be_false   # worker-a 持有
      store.lease_heartbeat("task-1", "worker-a", ttl: 30.seconds).should be_true # 心跳续租
      store.lease_acquire("task-1", "worker-b", ttl: 5.seconds).should be_false   # 续租后仍持有
      store.lease_release("task-1", "worker-a")
      store.lease_acquire("task-1", "worker-b", ttl: 200.milliseconds).should be_true # 释放后可取

      # 过期回收
      store.lease_acquire("task-2", "worker-a", ttl: 100.milliseconds)
      sleep 150.milliseconds
      reaped = store.lease_reap_expired
      reaped.should contain("task-2")
      store.lease_acquire("task-2", "worker-b", ttl: 1.seconds).should be_true
      store.close
    end
  end
end
