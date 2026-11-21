require "spec"
require "file_utils"
require "json"
require "../../../src/sessions/scheduling/scheduler"
require "../../../src/sessions/scheduling/recovery"
require "../../../src/platform/store/store"

# 测试工厂（顶层公开 def，循 gateway_spec 惯例）
def test_snapshot(max_pending_batches : Int64 = 32_i64, max_pending_bytes : Int64 = 262144_i64,
                  max_bytes : Int64 = 32768_i64) : Sebas::Sessions::Scheduling::PolicySnapshot
  Sebas::Sessions::Scheduling::PolicySnapshot.new("queue", 1000_i64, 5000_i64, 20_i64, max_bytes, true,
    "sender", 32_i64, max_pending_batches, max_pending_bytes, false, 300_i64, 16_i64, 30000_i64)
end

def test_env(session_key : String, event_id : String, content : String,
             snapshot : Sebas::Sessions::Scheduling::PolicySnapshot = test_snapshot) : Sebas::Sessions::Scheduling::InputEnvelope
  Sebas::Sessions::Scheduling::InputEnvelope.new(event_id, session_key, "email", "alice@example.com", 0,
    ::Time.utc.to_rfc3339, nil,
    %({"event_id": "#{event_id}", "channel_type": "email", "account_id": "acc", "peer": "alice@example.com", "content": #{content.inspect}}),
    snapshot)
end

def tmp_store(prefix : String) : ::Sebas::Platform::Store::Store
  dir = Path[::Dir.tempdir, "sebas-scheduler-spec", "#{prefix}-#{::Random::Secure.hex(4)}"]
  ::FileUtils.rm_rf(dir)
  ::Dir.mkdir_p(dir)
  ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
end

def make_batch(store : ::Sebas::Platform::Store::Store, session : String, first_seq : Int64,
               status : Sebas::Sessions::Scheduling::BatchStatus) : Sebas::Sessions::Scheduling::Batch
  batch_id = Sebas::Sessions::Scheduling.batch_id_for(session, first_seq)
  batch = Sebas::Sessions::Scheduling::Batch.new(batch_id, session, status, test_snapshot, first_seq, first_seq,
    ::Time.utc.to_rfc3339, nil, nil)
  store.create_session_batch(batch)
  batch
end

def batch_status(store : ::Sebas::Platform::Store::Store, batch_id : String) : String
  row = store.session_batch(batch_id)
  row ? row.status : "(missing)"
end

def first_input_status(store : ::Sebas::Platform::Store::Store, batch_id : String) : String
  rows = store.batch_inputs(batch_id)
  rows.empty? ? "(none)" : rows[0].status
end

module Sebas
  describe Sessions::Scheduling::SessionScheduler do
    it "admits and immediately dispatches in queue mode (receipt accepted + position 0)" do
      store = tmp_store("admit")
      dispatched = [] of String
      registry = Sessions::Scheduling::Registry.new(store)
      registry.dispatch_handler = ->(session_key : String, payload : String) { dispatched << "#{session_key}|#{payload}" }
      receipt = registry.admit(test_env("agent:main:acc:email:alice", "evt-1", "hello"))

      receipt.status.should eq("accepted")
      receipt.queue_position.should eq(0)
      receipt.batch_id.should_not be_empty
      dispatched.size.should eq(1)
      dispatched[0].should contain("batch_id")

      batch_status(store, receipt.batch_id).should eq("running") # 派发即 running（queued→running 受守卫迁移）
      inputs = store.batch_inputs(receipt.batch_id)
      inputs.size.should eq(1)
      inputs[0].status.should eq("dispatched")
      inputs[0].received_seq.should eq(1) # 持久接收序（§4.2）
      store.close
    end

    it "rejects duplicate event_id idempotently without a second batch" do
      store = tmp_store("dup")
      registry = Sessions::Scheduling::Registry.new(store)
      registry.dispatch_handler = ->(_s : String, _p : String) { }
      env = test_env("agent:main:acc:email:alice", "evt-dup", "hello")
      registry.admit(env).status.should eq("accepted")
      second = registry.admit(env)
      second.status.should eq("duplicate")
      store.pending_load("agent:main:acc:email:alice").batches.should eq(0) # running 批不算 pending
      store.close
    end

    it "queues behind a running batch and preserves FIFO order across batch_done" do
      store = tmp_store("fifo")
      order = [] of String
      registry = Sessions::Scheduling::Registry.new(store)
      registry.dispatch_handler = ->(_session_key : String, payload : String) { order << JSON.parse(payload)["batch_id"].as_s }
      session = "agent:main:acc:email:alice"
      r1 = registry.admit(test_env(session, "evt-a", "a"))
      r2 = registry.admit(test_env(session, "evt-b", "b"))
      r3 = registry.admit(test_env(session, "evt-c", "c"))

      r2.queue_position.should eq(0) # 前一批 running，本批为下一个待发
      r3.queue_position.should eq(1)
      order.size.should eq(1) # 会话忙：只派发过 head

      registry.batch_done(session, r1.batch_id)
      order.size.should eq(2)
      order[1].should eq(r2.batch_id)
      registry.batch_done(session, r2.batch_id)
      order.size.should eq(3)
      order[2].should eq(r3.batch_id)

      batch_status(store, r1.batch_id).should eq("done")
      batch_status(store, r3.batch_id).should eq("running")
      store.close
    end

    it "rejects admission at session backlog capacity with a counter (retryable)" do
      store = tmp_store("cap")
      snapshot = test_snapshot(max_pending_batches: 1_i64)
      registry = Sessions::Scheduling::Registry.new(store)
      registry.dispatch_handler = ->(_s : String, _p : String) { }
      session = "agent:main:acc:email:alice"
      # max_pending_batches=1：#1 立即派发（running 不占 pending）；#2 入 pending 队列；
      # #3 超限拒绝（pending 1 + 新批 1 > 1）
      registry.admit(test_env(session, "evt-1", "x", snapshot)).status.should eq("accepted")
      registry.admit(test_env(session, "evt-2", "y", snapshot)).status.should eq("accepted")
      receipt = registry.admit(test_env(session, "evt-3", "z", snapshot))
      receipt.status.should eq("rejected")
      registry.scheduler?(session).try(&.metrics["rejected_capacity"]).should eq(1)
      store.close
    end

    it "rejects a single input exceeding the batch byte budget" do
      store = tmp_store("bytes")
      snapshot = test_snapshot(max_bytes: 64_i64)
      registry = Sessions::Scheduling::Registry.new(store)
      registry.dispatch_handler = ->(_s : String, _p : String) { }
      receipt = registry.admit(test_env("agent:main:acc:email:alice", "evt-big", "x" * 100, snapshot))
      receipt.status.should eq("rejected")
      store.close
    end

    it "records member failure and transitions the batch to failed (successful members done)" do
      store = tmp_store("fail")
      registry = Sessions::Scheduling::Registry.new(store)
      registry.dispatch_handler = ->(_s : String, _p : String) { }
      session = "agent:main:acc:email:alice"
      # 构造双成员批次（WP3 debounce 的形态）：A 失败、B 成功 → 批次 failed、B done
      seq = store.next_session_seq(session)
      batch = Sessions::Scheduling::Batch.new(
        ::Sebas::Sessions::Scheduling.batch_id_for(session, seq), session,
        Sessions::Scheduling::BatchStatus::Collecting, test_snapshot, seq, seq,
        ::Time.utc.to_rfc3339, nil, nil)
      env_a = test_env(session, "evt-fa", "a")
      env_b = test_env(session, "evt-fb", "b")
      store.admit_new_batch(batch, env_a, 0)
      store.admit_session_input(env_b, batch, 1)
      store.transition_session_batch(batch.batch_id, Sessions::Scheduling::BatchStatus::Collecting,
        Sessions::Scheduling::BatchStatus::Sealed)
      store.transition_session_batch(batch.batch_id, Sessions::Scheduling::BatchStatus::Sealed,
        Sessions::Scheduling::BatchStatus::Queued)
      # 走真实派发路径（@running_batch 归 scheduler 所有），成员随派发置 dispatched
      registry.recover_dispatch
      batch_status(store, batch.batch_id).should eq("running")

      registry.batch_done(session, batch.batch_id, ["evt-fa"])
      batch_status(store, batch.batch_id).should eq("failed")
      statuses = store.batch_inputs(batch.batch_id).map(&.status)
      statuses.should eq(["failed", "done"]) # B 不残留 dispatched
      store.close
    end

    it "rejects stale completion callbacks without touching member states (atomic settle)" do
      store = tmp_store("stale2")
      registry = Sessions::Scheduling::Registry.new(store)
      registry.dispatch_handler = ->(_s : String, _p : String) { }
      session = "agent:main:acc:email:alice"
      receipt = registry.admit(test_env(session, "evt-k", "x"))
      # 模拟恢复改判：running → failed（成员未动）
      store.transition_session_batch(receipt.batch_id,
        Sessions::Scheduling::BatchStatus::Running, Sessions::Scheduling::BatchStatus::Failed)
      registry.batch_done(session, receipt.batch_id)                         # 陈旧回调：成员不得被标 done
      store.batch_inputs(receipt.batch_id)[0].status.should eq("dispatched") # 未被污染
      # 会话已空闲：后续 admission 可派发
      second = registry.admit(test_env(session, "evt-k2", "y"))
      second.status.should eq("accepted")
      store.close
    end

    it "re-queues the batch when the dispatch handoff fails (keeps it retryable)" do
      store = tmp_store("handoff")
      attempts = 0
      registry = Sessions::Scheduling::Registry.new(store)
      registry.dispatch_handler = ->(_s : String, _p : String) {
        attempts += 1
        raise "pool closed" if attempts == 1 # 首次交接失败
      }
      session = "agent:main:acc:email:alice"
      receipt = registry.admit(test_env(session, "evt-h", "x"))
      # 交接失败：批次回退 queued、在途标记已清
      store.pending_batches(session).map(&.batch_id).should eq([receipt.batch_id])
      # 下一次 kick 成功派发（批次仍可重试）
      registry.scheduler?(session).try(&.dispatch_if_idle)
      batch_status(store, receipt.batch_id).should eq("running")
      attempts.should eq(2)
      store.close
    end

    it "stops dispatching new batches after shutdown (pending stays for startup recovery)" do
      store = tmp_store("stop")
      order = [] of String
      registry = Sessions::Scheduling::Registry.new(store)
      registry.dispatch_handler = ->(_s : String, payload : String) { order << JSON.parse(payload)["batch_id"].as_s }
      session = "agent:main:acc:email:alice"
      r1 = registry.admit(test_env(session, "evt-p1", "a"))
      r2 = registry.admit(test_env(session, "evt-p2", "b"))
      scheduler = registry.scheduler?(session)
      scheduler.should_not be_nil
      scheduler.try(&.shutdown)
      registry.batch_done(session, r1.batch_id) # 在途批正常收敛……
      batch_status(store, r1.batch_id).should eq("done")
      order.size.should eq(1)                                                 # ……但下一批不再派发
      store.pending_batches(session).map(&.batch_id).should eq([r2.batch_id]) # B 留给启动恢复
      store.close
    end

    it "returns duplicate before capacity rejection for a retry of a queued event" do
      store = tmp_store("dupcap")
      snapshot = test_snapshot(max_pending_batches: 1_i64)
      registry = Sessions::Scheduling::Registry.new(store)
      registry.dispatch_handler = ->(_s : String, _p : String) { }
      session = "agent:main:acc:email:alice"
      registry.admit(test_env(session, "evt-d1", "x", snapshot)).status.should eq("accepted")
      registry.admit(test_env(session, "evt-d2", "y", snapshot)).status.should eq("accepted") # backlog 满
      # 重投已排队事件：duplicate（不占容量），而非 rejected
      registry.admit(test_env(session, "evt-d2", "y", snapshot)).status.should eq("duplicate")
      registry.scheduler?(session).try(&.metrics["rejected_capacity"]).should eq(0)
      store.close
    end

    it "ignores stale completion callbacks (recovery already re-judged)" do
      store = tmp_store("stale")
      registry = Sessions::Scheduling::Registry.new(store)
      registry.dispatch_handler = ->(_s : String, _p : String) { }
      session = "agent:main:acc:email:alice"
      receipt = registry.admit(test_env(session, "evt-s", "x"))
      # 模拟恢复改判：running → failed
      store.transition_session_batch(receipt.batch_id,
        Sessions::Scheduling::BatchStatus::Running, Sessions::Scheduling::BatchStatus::Failed)
      registry.batch_done(session, receipt.batch_id) # 陈旧回调：不得覆盖 failed
      batch_status(store, receipt.batch_id).should eq("failed")
      # 会话已空闲：后续 admission 可派发
      second = registry.admit(test_env(session, "evt-s2", "y"))
      second.status.should eq("accepted")
      second.queue_position.should eq(0)
      store.close
    end
  end

  describe Sessions::Scheduling::Recovery do
    it "seals leftover collecting batches with recovery reason and queues them" do
      store = tmp_store("collecting")
      session = "agent:main:acc:email:alice"
      batch = make_batch(store, session, 1, Sessions::Scheduling::BatchStatus::Collecting)
      store.admit_session_input(test_env(session, "evt-c", "x"), batch, 0) # 有成员：正常封存入队
      Sessions::Scheduling::Recovery.recover_stale(store)
      row = store.session_batch(batch.batch_id)
      row.should_not be_nil
      row.try(&.status).should eq("queued")
      row.try(&.seal_reason).should eq("recovery")
      store.close
    end

    it "fail-closes running batches whose turn may have started (intent dispatched)" do
      store = tmp_store("running")
      session = "agent:main:acc:email:alice"
      batch = make_batch(store, session, 1, Sessions::Scheduling::BatchStatus::Collecting)
      store.admit_session_input(test_env(session, "evt-r", "x"), batch, 0)
      store.record_intent("evt-r", "message", "{}")
      store.finish_intent("evt-r", "dispatched") # turn 可能已启动：副作用不可证
      # 推进到 running（模拟强杀前的在途批次）
      store.transition_session_batch(batch.batch_id, Sessions::Scheduling::BatchStatus::Collecting, Sessions::Scheduling::BatchStatus::Sealed)
      store.transition_session_batch(batch.batch_id, Sessions::Scheduling::BatchStatus::Sealed, Sessions::Scheduling::BatchStatus::Queued)
      store.transition_session_batch(batch.batch_id, Sessions::Scheduling::BatchStatus::Queued, Sessions::Scheduling::BatchStatus::Running)
      done = make_batch(store, session, 2, Sessions::Scheduling::BatchStatus::Done)

      Sessions::Scheduling::Recovery.recover_stale(store)
      batch_status(store, batch.batch_id).should eq("failed")
      first_input_status(store, batch.batch_id).should eq("failed")
      batch_status(store, done.batch_id).should eq("done") # 已完成不重跑
      store.close
    end

    it "settles running batches whose work completed (intent done, callback lost)" do
      store = tmp_store("settled")
      session = "agent:main:acc:email:alice"
      batch = make_batch(store, session, 1, Sessions::Scheduling::BatchStatus::Collecting)
      store.admit_session_input(test_env(session, "evt-sd", "x"), batch, 0)
      store.record_intent("evt-sd", "message", "{}")
      store.finish_intent("evt-sd", "done") # turn 已完成，回调丢失
      store.transition_session_batch(batch.batch_id, Sessions::Scheduling::BatchStatus::Collecting, Sessions::Scheduling::BatchStatus::Sealed)
      store.transition_session_batch(batch.batch_id, Sessions::Scheduling::BatchStatus::Sealed, Sessions::Scheduling::BatchStatus::Queued)
      store.transition_session_batch(batch.batch_id, Sessions::Scheduling::BatchStatus::Queued, Sessions::Scheduling::BatchStatus::Running)

      Sessions::Scheduling::Recovery.recover_stale(store)
      batch_status(store, batch.batch_id).should eq("done") # 不重跑
      first_input_status(store, batch.batch_id).should eq("done")
      store.close
    end

    it "requeues running batches whose turn never started (no intent)" do
      store = tmp_store("requeue")
      session = "agent:main:acc:email:alice"
      batch = make_batch(store, session, 1, Sessions::Scheduling::BatchStatus::Collecting)
      store.admit_session_input(test_env(session, "evt-rq", "x"), batch, 0)
      # 不录 intent：process_message 未及启动（intent 落库先于 turn）→ 消息不丢
      store.transition_session_batch(batch.batch_id, Sessions::Scheduling::BatchStatus::Collecting, Sessions::Scheduling::BatchStatus::Sealed)
      store.transition_session_batch(batch.batch_id, Sessions::Scheduling::BatchStatus::Sealed, Sessions::Scheduling::BatchStatus::Queued)
      store.transition_session_batch(batch.batch_id, Sessions::Scheduling::BatchStatus::Queued, Sessions::Scheduling::BatchStatus::Running)

      Sessions::Scheduling::Recovery.recover_stale(store)
      batch_status(store, batch.batch_id).should eq("queued") # 回退重派
      first_input_status(store, batch.batch_id).should eq("batched")
      # 重派一次成功（可继续走完批次生命周期）
      dispatched = [] of String
      registry = Sessions::Scheduling::Registry.new(store)
      registry.dispatch_handler = ->(_s : String, payload : String) { dispatched << payload }
      registry.recover_dispatch
      dispatched.size.should eq(1)
      store.close
    end

    it "fail-closes empty orphan batches instead of dispatching them" do
      store = tmp_store("empty")
      session = "agent:main:acc:email:alice"
      batch = make_batch(store, session, 1, Sessions::Scheduling::BatchStatus::Collecting) # 无成员输入的孤儿批

      Sessions::Scheduling::Recovery.recover_stale(store)
      batch_status(store, batch.batch_id).should eq("failed")
      store.pending_batches(session).should be_empty
      store.close
    end

    it "leaves pending batches re-dispatchable exactly once via guarded transition" do
      store = tmp_store("pending")
      session = "agent:main:acc:email:alice"
      batch = make_batch(store, session, 1, Sessions::Scheduling::BatchStatus::Queued)
      dispatched = [] of String
      registry = Sessions::Scheduling::Registry.new(store)
      registry.dispatch_handler = ->(_s : String, payload : String) { dispatched << payload }
      Sessions::Scheduling::Recovery.recover_stale(store)
      registry.recover_dispatch
      registry.recover_dispatch # 双重 kick 不得双派发（queued→running 守卫）
      dispatched.size.should eq(1)
      dispatched[0].should contain(batch.batch_id)
      store.close
    end
  end
end
