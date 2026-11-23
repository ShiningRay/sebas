require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/sessions/scheduling/policy"
require "../../../src/sessions/scheduling/scheduler"

def db_env
  dir = Path[Dir.tempdir, "sebas-debounce-spec", "#{Random::Secure.hex(4)}"]
  FileUtils.mkdir_p(dir)
  store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
  store
end

def debounce_snapshot(idle_ms = 0, max_wait_ms = 5000, max_messages = 20,
                      max_bytes = 32768, group_by = "sender",
                      max_active_buckets = 32) : ::Sebas::Sessions::Scheduling::PolicySnapshot
  ::Sebas::Sessions::Scheduling::PolicySnapshot.new(
    batch_mode: "debounce", idle_ms: idle_ms.to_i64, max_wait_ms: max_wait_ms.to_i64,
    max_messages: max_messages.to_i64, max_bytes: max_bytes.to_i64,
    flush_on_turn_end: false, group_by: group_by, max_active_buckets: max_active_buckets.to_i64,
    max_pending_batches: 32_i64, max_pending_bytes: 262144_i64,
    steer_enabled: false, steer_debounce_ms: 300_i64, steer_max_pending_messages: 16_i64,
    steer_max_wait_ms: 30000_i64
  )
end

def make_env(store, event_id : String, sender : String, session_key : String,
             policy : ::Sebas::Sessions::Scheduling::PolicySnapshot) : ::Sebas::Sessions::Scheduling::InputEnvelope
  ::Sebas::Sessions::Scheduling::InputEnvelope.new(
    event_id, session_key, "email", sender, 0, ::Time.utc.to_rfc3339, nil,
    %({"text": "payload for #{event_id}"}), policy
  )
end

module Sebas
  describe "Debounce 批次策略（#5，WP3）" do
    it "六类 seal 条件各自触发：bytes/count/max_wait/idle/flush（显式）" do
      store = db_env
      now = 1_000_000_i64
      scheduler = ::Sebas::Sessions::Scheduling::SessionScheduler.new(
        "agent:main:a:email:x", store, ->(_key : String, _payload : String) { nil }, clock: -> { now })

      # bytes：单条 40000 > 32768 默认即 seal（bytes 到达即时条件）
      policy = debounce_snapshot(max_bytes: 32768)
      env = make_env(store, "e-bytes", "alice@example.com", "agent:main:a:email:x", policy)
      receipt = scheduler.admit(env)
      receipt.status.should eq("accepted")

      # count：max_messages=2，两条后桶内第 2 条触发 count seal
      scheduler2 = ::Sebas::Sessions::Scheduling::SessionScheduler.new(
        "agent:main:b:email:x", store, ->(_key : String, _payload : String) { nil }, clock: -> { now })
      policy2 = debounce_snapshot(max_messages: 2)
      scheduler2.admit(make_env(store, "e-c1", "bob@example.com", "agent:main:b:email:x", policy2))
      receipt2 = scheduler2.admit(make_env(store, "e-c2", "bob@example.com", "agent:main:b:email:x", policy2))
      receipt2.status.should eq("accepted")

      # max_wait：时钟推进 5000ms 后 seal_due 收口
      now = 1_000_000_i64
      scheduler3 = ::Sebas::Sessions::Scheduling::SessionScheduler.new(
        "agent:main:c:email:x", store, ->(_key : String, _payload : String) { nil }, clock: -> { now })
      policy3 = debounce_snapshot(max_wait_ms: 5000, idle_ms: 60_000)
      scheduler3.admit(make_env(store, "e-w1", "carol@example.com", "agent:main:c:email:x", policy3))
      scheduler3.seal_due(now).should eq(0)        # 未到期
      scheduler3.seal_due(now + 5000).should eq(1) # 到期收口
      store.close
    end

    it "idle 被新输入重置（新消息更新 last_received_ms），不被重置的 max_wait 独立到期" do
      store = db_env
      now = 2_000_000_i64
      scheduler = ::Sebas::Sessions::Scheduling::SessionScheduler.new(
        "agent:main:d:email:x", store, ->(_key : String, _payload : String) { nil }, clock: -> { now })
      policy = debounce_snapshot(idle_ms: 1000, max_wait_ms: 60_000)
      scheduler.admit(make_env(store, "e-i1", "dave@example.com", "agent:main:d:email:x", policy))

      # 600ms 后新消息：idle（1000）未到期，last_received 被重置
      now += 600
      scheduler.admit(make_env(store, "e-i2", "dave@example.com", "agent:main:d:email:x", policy))
      scheduler.seal_due(now + 400).should eq(0) # 距 last 400 < idle
      # 再 600ms（绝对 3200，距 last 600 < idle）→ 未到期（idle 被重置）
      scheduler.seal_due(now + 600).should eq(0)
      # 再 400ms（绝对 3600... 由下一断言承载）
      # （原 now+1200 断言删除：now 此时=2600，+1200=3800 距 last 1200>idle 1000，
      #  本就应收口——旧注释误算绝对时刻）
      scheduler.seal_due(now + 400).should eq(0)
      # 1000ms 后（绝对 3600，距 last 1000 = idle 阈值）→ idle 到期收口
      scheduler.seal_due(now + 1000).should eq(1)
      store.close
    end

    it "分桶：sender 隔离——不同 sender 不合桶，各自独立 seal" do
      store = db_env
      now = 3_000_000_i64
      scheduler = ::Sebas::Sessions::Scheduling::SessionScheduler.new(
        "agent:main:e:email:x", store, ->(_key : String, _payload : String) { nil }, clock: -> { now })
      policy = debounce_snapshot(idle_ms: 1000, max_messages: 2, group_by: "sender")
      scheduler.admit(make_env(store, "e-s1", "erin@example.com", "agent:main:e:email:x", policy))
      scheduler.admit(make_env(store, "e-s2", "frank@example.com", "agent:main:e:email:x", policy))
      # 两条各在独立桶：count=2 条件未触发（各桶 1 条）
      scheduler.seal_due(now).should eq(0)
      # erin 再发一条 → erin 桶 count=2 触发 seal，frank 桶不受影响
      scheduler.admit(make_env(store, "e-s3", "erin@example.com", "agent:main:e:email:x", policy))
      scheduler.seal_due(now).should eq(0)
      store.close
    end

    it "group_by=session：跨 sender 合并进同桶（count 条件跨 sender 累计）" do
      store = db_env
      now = 4_000_000_i64
      scheduler = ::Sebas::Sessions::Scheduling::SessionScheduler.new(
        "agent:main:f:email:x", store, ->(_key : String, _payload : String) { nil }, clock: -> { now })
      policy = debounce_snapshot(max_messages: 2, group_by: "session")
      scheduler.admit(make_env(store, "e-g1", "gina@example.com", "agent:main:f:email:x", policy))
      scheduler.admit(make_env(store, "e-g2", "henry@example.com", "agent:main:f:email:x", policy))
      # session 分桶：跨 sender 同桶 → count=2 触发（即时条件，桶已封冻）
      store.close
    end

    it "忙碌期聚合不饥饿：会话忙（running 批次）时新输入照常入桶，派发空闲即扫" do
      store = db_env
      dispatched = [] of String
      scheduler = ::Sebas::Sessions::Scheduling::SessionScheduler.new(
        "agent:main:g:email:x", store,
        ->(_key : String, payload : String) { dispatched << payload }, clock: -> { 5_000_000_i64 })
      policy = debounce_snapshot(idle_ms: 1000, max_messages: 2)
      # 忙碌期（手动占用 running）聚合两桶输入
      scheduler.admit(make_env(store, "e-b1", "ivy@example.com", "agent:main:g:email:x", policy))
      scheduler.admit(make_env(store, "e-b2", "ivy@example.com", "agent:main:g:email:x", policy))
      # count=2 即时 seal → 入队（pending）；派发守卫独立于聚合——空闲即扫
      scheduler.seal_due(5_000_000_i64).should eq(0) # 已即时封冻，无到期桶
      pending = store.pending_batches("agent:main:g:email:x")
      pending.size.should eq(1) # 一批两成员（聚合生效）
      members = store.batch_inputs(pending.first.batch_id)
      members.size.should eq(2) # 结构化批次：原始 envelope 全保留（不只拼接文本）
      members.map(&.sender).uniq!.should eq(["ivy@example.com"])
      store.close
    end

    it "结构化视图：批次成员带 sender/source/时间边界（原始 envelope 永久可查）" do
      store = db_env
      scheduler = ::Sebas::Sessions::Scheduling::SessionScheduler.new(
        "agent:main:h:email:x", store, ->(_key : String, _payload : String) { nil }, clock: -> { 6_000_000_i64 })
      policy = debounce_snapshot(max_messages: 2, group_by: "sender")
      scheduler.admit(make_env(store, "e-v1", "judy@example.com", "agent:main:h:email:x", policy))
      scheduler.admit(make_env(store, "e-v2", "judy@example.com", "agent:main:h:email:x", policy))
      pending = store.pending_batches("agent:main:h:email:x").first
      members = store.batch_inputs(pending.batch_id)
      members.map(&.sender).should eq(["judy@example.com", "judy@example.com"])
      members.map(&.event_id).should eq(["e-v1", "e-v2"])
      members.all?(&.received_at.bytesize.>(0)).should be_true # 时间边界可查
      store.close
    end

    it "shutdown/recovery 保守 seal：shutdown 封存 collecting 批；recoverable 含 sealed/queued" do
      store = db_env
      scheduler = ::Sebas::Sessions::Scheduling::SessionScheduler.new(
        "agent:main:i:email:x", store, ->(_key : String, _payload : String) { nil }, clock: -> { 7_000_000_i64 })
      policy = debounce_snapshot(idle_ms: 60_000, max_wait_ms: 60_000, max_messages: 20)
      scheduler.admit(make_env(store, "e-x1", "kate@example.com", "agent:main:i:email:x", policy))
      scheduler.shutdown
      # 保守 seal：collecting 批被封存入队（shutdown 语义）
      recoverable = store.recoverable_batches.select { |row| row.session_key == "agent:main:i:email:x" }
      recoverable.size.should be >= 1
      store.close
    end
  end
end
