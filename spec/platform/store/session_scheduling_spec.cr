require "spec"
require "file_utils"
require "../../../src/platform/store/store"

# spec 助手（Crystal 1.22 不允许 def 直接出现在 describe 块内，置于顶层）
def sched_store(name : String) : ::Sebas::Platform::Store::Store
  dir = Path[Dir.tempdir, "sebas-sched-spec", name]
  FileUtils.rm_rf(dir)
  ::Sebas::Platform::Store::Store.new(dir / "store.db", dir / "sessions")
end

def sched_envelope(event_id : String, session : String = "sess-a",
                   sender : String = "alice", payload : String = "hello",
                   seq : Int64 = 1_i64) : ::Sebas::Sessions::Scheduling::InputEnvelope
  ::Sebas::Sessions::Scheduling::InputEnvelope.new(
    event_id, session, "email", sender, seq, "2026-01-01T00:00:00Z", nil,
    payload, ::Sebas::Sessions::Scheduling::Policy.builtin)
end

def sched_batch(batch_id : String, session : String = "sess-a",
                first : Int64 = 1_i64, last : Int64 = 1_i64) : ::Sebas::Sessions::Scheduling::Batch
  ::Sebas::Sessions::Scheduling::Batch.new(batch_id, session,
    ::Sebas::Sessions::Scheduling::BatchStatus::Collecting,
    ::Sebas::Sessions::Scheduling::Policy.builtin, first, last, "2026-01-01T00:00:00Z", nil, nil)
end

describe "会话输入调度持久化（M3-WP1）" do
  describe "migration（§5.1）" do
    it "幂等：同一路径重复打开不报错、数据不丢" do
      dir = Path[Dir.tempdir, "sebas-sched-spec", "migration-idem"]
      FileUtils.rm_rf(dir)
      store = ::Sebas::Platform::Store::Store.new(dir / "store.db")
      store.record_intent("req-1", "message")
      store.close
      store2 = ::Sebas::Platform::Store::Store.new(dir / "store.db")
      store2.intent_status("req-1").should eq("pending")
      store2.close
    end

    it "老库升级兼容：旧库数据在新代码打开后保留，session 表就位" do
      dir = Path[Dir.tempdir, "sebas-sched-spec", "old-db"]
      FileUtils.rm_rf(dir)
      store = ::Sebas::Platform::Store::Store.new(dir / "store.db")
      store.record_intent("req-old", "message")
      task_old = store.create_task("t-old", "run")
      store.complete_task(task_old.id)
      store.close
      store2 = ::Sebas::Platform::Store::Store.new(dir / "store.db")
      store2.intent_status("req-old").should eq("pending") # 老数据完好
      store2.task_status?("t-old").should eq("done")
      store2.collecting_batches.size.should eq(0) # 新表可用（空）
      store2.close
    end
  end

  describe "admission 原子性（§4.2：去重+持久化+入批同事务）" do
    it "首次 admit 成功并写入成员关系；同 event_id 二次投递返回 false" do
      store = sched_store("admit-dedup")
      batch = sched_batch("sess-a:batch:1")
      store.create_session_batch(batch)
      env = sched_envelope("evt-1", seq: 1_i64)
      store.admit_session_input(env, batch, 0).should be_true
      store.admit_session_input(env, batch, 0).should be_false # 幂等：不产生第二行
      inputs = store.batch_inputs("sess-a:batch:1")
      inputs.size.should eq(1)
      inputs.first.event_id.should eq("evt-1")
      inputs.first.status.should eq("batched")
      store.close
    end

    it "一批多事件：position 唯一约束拒绝重复位次（顺序不可重排）" do
      store = sched_store("member-unique")
      batch = sched_batch("sess-a:batch:1")
      store.create_session_batch(batch)
      store.admit_session_input(sched_envelope("evt-1", seq: 1_i64), batch, 0).should be_true
      store.admit_session_input(sched_envelope("evt-2", sender: "bob", seq: 2_i64), batch, 1).should be_true
      expect_raises(::Exception) do
        store.admit_session_input(sched_envelope("evt-3", sender: "carol", seq: 3_i64), batch, 1) # 位次 1 重复
      end
      store.batch_inputs("sess-a:batch:1").size.should eq(2)
      store.close
    end

    it "批内按 position 保序（原始顺序可追溯）" do
      store = sched_store("member-order")
      batch = sched_batch("sess-a:batch:1")
      store.create_session_batch(batch)
      store.admit_session_input(sched_envelope("evt-2", payload: "second", seq: 2_i64), batch, 1).should be_true
      store.admit_session_input(sched_envelope("evt-1", payload: "first", seq: 1_i64), batch, 0).should be_true
      inputs = store.batch_inputs("sess-a:batch:1")
      inputs.map(&.event_id).should eq(["evt-1", "evt-2"]) # 按 position 而非插入顺序
      store.close
    end
  end

  describe "批次状态迁移（受守卫；§5.1 状态机）" do
    it "collecting → sealed（带 seal_reason + sealed_at）" do
      store = sched_store("seal-guard")
      batch = sched_batch("sess-a:batch:1")
      store.create_session_batch(batch)
      store.transition_session_batch("sess-a:batch:1",
        ::Sebas::Sessions::Scheduling::BatchStatus::Collecting,
        ::Sebas::Sessions::Scheduling::BatchStatus::Sealed, seal_reason: "bytes").should be_true
      row = store.session_batch("sess-a:batch:1").should_not be_nil
      row.status.should eq("sealed")
      row.seal_reason.should eq("bytes")
      store.close
    end

    it "迁移守卫：已 sealed 后再从 collecting 迁移失败（竞态双保险）" do
      store = sched_store("seal-twice")
      batch = sched_batch("sess-a:batch:1")
      store.create_session_batch(batch)
      store.transition_session_batch("sess-a:batch:1",
        ::Sebas::Sessions::Scheduling::BatchStatus::Collecting,
        ::Sebas::Sessions::Scheduling::BatchStatus::Sealed).should be_true
      store.transition_session_batch("sess-a:batch:1",
        ::Sebas::Sessions::Scheduling::BatchStatus::Collecting,
        ::Sebas::Sessions::Scheduling::BatchStatus::Sealed).should be_false
      store.close
    end

    it "admission 拒绝非 collecting 批次（事务内前置校验，独立于唯一约束）" do
      store = sched_store("admit-not-collecting")
      batch = sched_batch("sess-a:batch:1")
      store.create_session_batch(batch)
      store.transition_session_batch("sess-a:batch:1",
        ::Sebas::Sessions::Scheduling::BatchStatus::Collecting,
        ::Sebas::Sessions::Scheduling::BatchStatus::Sealed, seal_reason: "idle").should be_true
      expect_raises(::Sebas::Platform::Store::StoreError, "not collecting") do
        store.admit_session_input(sched_envelope("evt-late", seq: 9_i64), batch, 1)
      end
      store.batch_inputs("sess-a:batch:1").size.should eq(0) # 输入未入已 sealed 批
      store.close
    end

    it "重复投递已 sealed 批次中的同 event_id → 幂等返回 false（去重先于状态守卫）" do
      store = sched_store("dup-sealed-batch")
      batch = sched_batch("sess-a:batch:1")
      store.create_session_batch(batch)
      env = sched_envelope("evt-1", seq: 1_i64)
      store.admit_session_input(env, batch, 0).should be_true
      store.transition_session_batch("sess-a:batch:1",
        ::Sebas::Sessions::Scheduling::BatchStatus::Collecting,
        ::Sebas::Sessions::Scheduling::BatchStatus::Sealed, seal_reason: "idle").should be_true
      store.admit_session_input(env, batch, 0).should be_false # 不抛 StoreError
      store.close
    end

    it "seal 后输入必入下一批：原批不再接受新成员（调用方开新批，唯一约束兜底）" do
      store = sched_store("seal-then-next")
      batch = sched_batch("sess-a:batch:1")
      store.create_session_batch(batch)
      store.admit_session_input(sched_envelope("evt-1", seq: 1_i64), batch, 0).should be_true
      store.transition_session_batch("sess-a:batch:1",
        ::Sebas::Sessions::Scheduling::BatchStatus::Collecting,
        ::Sebas::Sessions::Scheduling::BatchStatus::Sealed, seal_reason: "idle").should be_true
      next_batch = sched_batch("sess-a:batch:2", first: 2_i64, last: 2_i64)
      store.create_session_batch(next_batch)
      store.admit_session_input(sched_envelope("evt-2", seq: 2_i64), next_batch, 0).should be_true
      store.batch_inputs("sess-a:batch:1").map(&.event_id).should eq(["evt-1"])
      store.batch_inputs("sess-a:batch:2").map(&.event_id).should eq(["evt-2"]) # 无双归属
      store.close
    end
  end

  describe "启动恢复查询（§5.2）" do
    it "collecting 批次按原快照分流（recovery seal 口径）" do
      store = sched_store("recover-collecting")
      store.create_session_batch(sched_batch("sess-a:batch:1"))
      store.create_session_batch(sched_batch("sess-b:batch:9", session: "sess-b"))
      store.collecting_batches.size.should eq(2)
      store.collecting_batches("sess-b").map(&.batch_id).should eq(["sess-b:batch:9"])
      store.close
    end

    it "sealed/queued 重新入队（recoverable_batches）" do
      store = sched_store("recover-sealed")
      store.create_session_batch(sched_batch("sess-a:batch:1"))
      store.transition_session_batch("sess-a:batch:1",
        ::Sebas::Sessions::Scheduling::BatchStatus::Collecting,
        ::Sebas::Sessions::Scheduling::BatchStatus::Sealed).should be_true
      store.collecting_batches.size.should eq(0)
      store.recoverable_batches.map(&.batch_id).should eq(["sess-a:batch:1"])
      store.transition_session_batch("sess-a:batch:1",
        ::Sebas::Sessions::Scheduling::BatchStatus::Sealed,
        ::Sebas::Sessions::Scheduling::BatchStatus::Queued).should be_true
      store.recoverable_batches.size.should eq(1)
      store.close
    end
  end

  describe "busy steer 持久化（accepted ≠ injected，§4.4）" do
    it "accepted 落库 → injected 原子迁移 → 重复迁移失败（不伪报成功）" do
      store = sched_store("steer-state")
      store.record_session_steer("st-1", "sess-a", "turn-1", 1, "改用 ruby").should be_true
      store.record_session_steer("st-1", "sess-a", "turn-1", 1, "改用 ruby").should be_false # 幂等
      store.transition_session_steer("st-1",
        ::Sebas::Sessions::Scheduling::SteerStatus::Accepted,
        ::Sebas::Sessions::Scheduling::SteerStatus::Injected).should be_true
      store.transition_session_steer("st-1",
        ::Sebas::Sessions::Scheduling::SteerStatus::Accepted,
        ::Sebas::Sessions::Scheduling::SteerStatus::Injected).should be_false
      rows = store.session_steers("sess-a")
      rows.first.status.should eq("injected")
      store.close
    end

    it "未注入 steer 在崩溃恢复口径下转 queued 并记录原因（不伪报）" do
      store = sched_store("steer-recovery")
      store.record_session_steer("st-2", "sess-a", "turn-1", 1, "先跑测试")
      store.transition_session_steer("st-2",
        ::Sebas::Sessions::Scheduling::SteerStatus::Accepted,
        ::Sebas::Sessions::Scheduling::SteerStatus::Queued, reason: "recovery_not_injected").should be_true
      store.session_steers("sess-a", "queued").first.reason.should eq("recovery_not_injected")
      store.close
    end
  end
end
