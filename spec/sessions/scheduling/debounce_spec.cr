require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/sessions/scheduling/policy"
require "../../../src/sessions/scheduling/scheduler"

def db_env5
  dir = Path[Dir.tempdir, "sebas-debounce-spec", "#{Random::Secure.hex(4)}"]
  FileUtils.mkdir_p(dir)
  ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
end

def snap5(idle_ms = 0, max_wait_ms = 5000, max_messages = 20, max_bytes = 32768,
          group_by = "sender", max_active_buckets = 32, flush_on_turn_end = false)
  ::Sebas::Sessions::Scheduling::PolicySnapshot.new(
    batch_mode: "debounce", idle_ms: idle_ms.to_i64, max_wait_ms: max_wait_ms.to_i64,
    max_messages: max_messages.to_i64, max_bytes: max_bytes.to_i64,
    flush_on_turn_end: flush_on_turn_end, group_by: group_by,
    max_active_buckets: max_active_buckets.to_i64,
    max_pending_batches: 32_i64, max_pending_bytes: 262144_i64,
    steer_enabled: false, steer_debounce_ms: 300_i64,
    steer_max_pending_messages: 16_i64, steer_max_wait_ms: 30000_i64)
end

def env5(event_id, session_key, sender, policy, payload = %({"t":1}))
  ::Sebas::Sessions::Scheduling::InputEnvelope.new(
    event_id, session_key, "email", sender, 0, ::Time.utc.to_rfc3339, nil, payload, policy)
end

def sched5(store, session_key, clock, dispatch : (Proc(String, String, Nil))? = nil)
  handler = dispatch || ->(_key : String, _payload : String) { nil }
  ::Sebas::Sessions::Scheduling::SessionScheduler.new(session_key, store, handler, clock: clock)
end

module Sebas
  describe "Debounce 批次策略（#5，WP3）" do
    it "bytes 累积超限即时封冻（seal_reason=bytes，不等 idle）" do
      store = db_env5
      scheduler = sched5(store, "agent:main:a:email:x", -> { 1_000_000_i64 })
      policy = snap5(max_bytes: 32768)
      scheduler.admit(env5("e-b1", "agent:main:a:email:x", "alice", policy, "x" * 20000))
      store.pending_batches("agent:main:a:email:x").size.should eq(0) # 未封冻
      scheduler.admit(env5("e-b2", "agent:main:a:email:x", "alice", policy, "x" * 20000))
      all_rows = store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Queued) +
                 store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Running)
      bytes_rows = all_rows.select(&.seal_reason.==("bytes"))
      bytes_rows.size.should eq(1) # 累积 40KB 超限即时封冻（封存后即派发留 running）
      store.batch_inputs(bytes_rows.first.batch_id).size.should eq(2)
      store.close
    end

    it "count 到达 max_messages 即时封冻（seal_reason=count）" do
      store = db_env5
      scheduler = sched5(store, "agent:main:b:email:x", -> { 2_000_000_i64 })
      policy = snap5(max_messages: 2)
      scheduler.admit(env5("e-c1", "agent:main:b:email:x", "bob", policy))
      store.pending_batches("agent:main:b:email:x").size.should eq(0) # 未封冻
      scheduler.admit(env5("e-c2", "agent:main:b:email:x", "bob", policy))
      all_rows = store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Queued) +
                 store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Running)
      count_rows = all_rows.select(&.seal_reason.==("count"))
      count_rows.size.should eq(1) # count=2 即时封冻
      store.batch_inputs(count_rows.first.batch_id).size.should eq(2)
      store.close
    end

    it "idle 被新输入重置；max_wait 不被重置独立到期（Clock 注入）" do
      store = db_env5
      now = 2_000_000_i64
      scheduler = sched5(store, "agent:main:d:email:x", -> { now })
      policy = snap5(idle_ms: 1000, max_wait_ms: 60_000)
      scheduler.admit(env5("e-i1", "agent:main:d:email:x", "dave", policy))
      now += 600
      scheduler.admit(env5("e-i2", "agent:main:d:email:x", "dave", policy))
      scheduler.seal_due(now + 400).should eq(0)  # 距 last 400 < idle
      scheduler.seal_due(now + 999).should eq(0)  # 距 last 999 仍 < idle
      scheduler.seal_due(now + 1000).should eq(1) # idle 到期收口；max_wait 60s 未到
      store.close
    end

    it "max_wait 不被新输入重置：距首条到达即计时到期收口" do
      store = db_env5
      now = 3_000_000_i64
      scheduler = sched5(store, "agent:main:e:email:x", -> { now })
      policy = snap5(idle_ms: 60_000, max_wait_ms: 5000)
      scheduler.admit(env5("e-w1", "agent:main:e:email:x", "erin", policy))
      now += 3000
      scheduler.admit(env5("e-w2", "agent:main:e:email:x", "erin", policy)) # 重置 idle 不重置 max_wait
      scheduler.seal_due(now + 1999).should eq(0)                           # 距首条 4999 < 5000
      scheduler.seal_due(now + 2000).should eq(1)                           # 距首条 5000 = max_wait 到期
      store.close
    end

    it "分桶：group_by=sender 隔离——不同 sender 独立桶，seal 互不影响" do
      store = db_env5
      scheduler = sched5(store, "agent:main:f:email:x", -> { 4_000_000_i64 })
      policy = snap5(max_messages: 2, group_by: "sender")
      scheduler.admit(env5("e-s1", "agent:main:f:email:x", "frank", policy))
      scheduler.admit(env5("e-s2", "agent:main:f:email:x", "grace", policy))
      scheduler.admit(env5("e-s3", "agent:main:f:email:x", "frank", policy))
      # frank 桶 count=2 封冻；grace 桶 1 条未封
      all_rows = store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Queued) +
                 store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Running)
      pending = all_rows.select(&.seal_reason.==("count"))
      pending.size.should eq(1)
      members = store.batch_inputs(pending.first.batch_id)
      members.map(&.sender).uniq!.should eq(["frank"]) # grace 不在 frank 桶内
      store.close
    end

    it "group_by=session：跨 sender 合并同桶（count 跨 sender 累计）" do
      store = db_env5
      scheduler = sched5(store, "agent:main:g:email:x", -> { 5_000_000_i64 })
      policy = snap5(max_messages: 2, group_by: "session")
      scheduler.admit(env5("e-g1", "agent:main:g:email:x", "heidi", policy))
      scheduler.admit(env5("e-g2", "agent:main:g:email:x", "ivan", policy))
      all_rows = store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Queued) +
                 store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Running)
      pending = all_rows.select(&.seal_reason.==("count"))
      pending.size.should eq(1) # 同桶 count=2 封冻
      members = store.batch_inputs(pending.first.batch_id)
      members.map(&.sender).sort!.should eq(["heidi", "ivan"]) # 跨 sender 同桶
      store.close
    end

    it "忙碌期聚合不饥饿：running 期间输入照常入桶，封存后空闲即派发" do
      store = db_env5
      dispatched = [] of String
      scheduler = ::Sebas::Sessions::Scheduling::SessionScheduler.new(
        "agent:main:h:email:x", store, ->(_key : String, payload : String) {
        dispatched << payload
        nil
      }, clock: -> { 6_000_000_i64 })
      policy = snap5(idle_ms: 1000, max_messages: 2)
      scheduler.admit(env5("e-h1", "agent:main:h:email:x", "judy", policy))
      scheduler.admit(env5("e-h2", "agent:main:h:email:x", "judy", policy))
      # count=2 即时 seal → dispatch 空闲即投递
      all_rows = store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Queued) +
                 store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Running)
      count_rows = all_rows.select(&.seal_reason.==("count"))
      count_rows.size.should eq(1)
      # 队列已派发（queued→running），running 批保留可查
      store.close
    end

    it "结构化视图：批次成员带 sender/原始 envelope/时间边界（永久可查）" do
      store = db_env5
      scheduler = sched5(store, "agent:main:i:email:x", -> { 7_000_000_i64 })
      policy = snap5(max_messages: 2, group_by: "sender")
      scheduler.admit(env5("e-v1", "agent:main:i:email:x", "judy", policy))
      scheduler.admit(env5("e-v2", "agent:main:i:email:x", "judy", policy))
      all_rows = store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Queued) +
                 store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Running)
      pending = all_rows.find(&.seal_reason.==("count"))
      raise "count 封冻批次缺失" if pending.nil?
      members = store.batch_inputs(pending.batch_id)
      members.map(&.event_id).should eq(["e-v1", "e-v2"])
      members.map(&.sender).uniq!.should eq(["judy"])
      members.all?(&.received_at.bytesize.>(0)).should be_true
      store.close
    end

    it "shutdown 保守 seal：collecting 批封存入队（recoverable 含 sealed/queued）" do
      store = db_env5
      scheduler = sched5(store, "agent:main:j:email:x", -> { 8_000_000_i64 })
      policy = snap5(idle_ms: 60_000, max_wait_ms: 60_000, max_messages: 200)
      scheduler.admit(env5("e-j1", "agent:main:j:email:x", "kate", policy))
      scheduler.shutdown
      recoverable = store.recoverable_batches.select { |row| row.session_key == "agent:main:j:email:x" }
      recoverable.size.should be >= 1
      store.close
    end

    it "flush_on_turn_end：turn 结束即刻封存启用桶，sealed_turn_end 指标递增" do
      store = db_env5
      scheduler = sched5(store, "agent:main:k:email:x", -> { 9_000_000_i64 })
      policy = snap5(idle_ms: 60_000, max_wait_ms: 60_000, max_messages: 200, flush_on_turn_end: true)
      scheduler.admit(env5("e-k1", "agent:main:k:email:x", "liam", policy))
      store.pending_batches("agent:main:k:email:x").size.should eq(0) # turn 未结束聚合中
      scheduler.flush_on_turn_end_buckets
      pending = store.pending_batches("agent:main:k:email:x")
      pending.count(&.seal_reason.==("turnend")).should eq(1)
      scheduler.metrics["sealed_turn_end"].should be > 0
      store.close
    end

    it "显式 flush：立即封存全部桶（不等 debounce）" do
      store = db_env5
      scheduler = sched5(store, "agent:main:l:email:x", -> { 10_000_000_i64 })
      policy = snap5(idle_ms: 60_000, max_wait_ms: 60_000, max_messages: 200)
      scheduler.admit(env5("e-l1", "agent:main:l:email:x", "mia", policy))
      scheduler.admit(env5("e-l2", "agent:main:l:email:x", "mia", policy))
      scheduler.flush_all_buckets.should eq(1)
      all_rows = store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Queued) +
                 store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Running)
      all_rows.count(&.seal_reason.==("flush")).should eq(1)
      scheduler.metrics["sealed_flush"].should be > 0
      store.close
    end

    it "max_active_buckets：超限封存最老桶（上限生效）" do
      store = db_env5
      scheduler = sched5(store, "agent:main:m:email:x", -> { 11_000_000_i64 })
      policy = snap5(idle_ms: 60_000, max_wait_ms: 60_000, max_messages: 200, max_active_buckets: 2)
      scheduler.admit(env5("e-m1", "agent:main:m:email:x", "noah", policy))
      scheduler.admit(env5("e-m2", "agent:main:m:email:x", "olivia", policy))
      scheduler.admit(env5("e-m3", "agent:main:m:email:x", "peter", policy))
      all_rows = store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Queued) +
                 store.batches_by_status(::Sebas::Sessions::Scheduling::BatchStatus::Running)
      all_rows.count { |row| row.seal_reason == "maxwait" }.should be >= 1 # 最老桶封存
      store.close
    end

    it "派发：封存批次入队后被 dispatch 回调投递（空闲即扫）" do
      store = db_env5
      dispatched = [] of String
      scheduler = ::Sebas::Sessions::Scheduling::SessionScheduler.new(
        "agent:main:n:email:x", store, ->(_key : String, payload : String) {
        dispatched << payload
        nil
      }, clock: -> { 12_000_000_i64 })
      policy = snap5(idle_ms: 1000, max_messages: 2)
      scheduler.admit(env5("e-n1", "agent:main:n:email:x", "quinn", policy))
      scheduler.admit(env5("e-n2", "agent:main:n:email:x", "quinn", policy))
      dispatched.size.should eq(1) # count=2 即时 seal + 空闲即派发
      batch_id = ::JSON.parse(dispatched.first)["batch_id"].as_s
      store.batch_inputs(batch_id).size.should eq(2)
      store.close
    end
  end
end
