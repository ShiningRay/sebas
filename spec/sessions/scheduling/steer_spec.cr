require "spec"
require "file_utils"
require "../../../src/platform/store/store"
require "../../../src/sessions/scheduling/steer"
require "../../../src/sessions/scheduling/policy"

# 启用 steer 的策略快照（debounce/过期判定可控）
def steer_test_policy(max_wait_ms : Int64 = 30_000, debounce_ms : Int64 = 300) : ::Sebas::Sessions::Scheduling::PolicySnapshot
  ::Sebas::Sessions::Scheduling::PolicySnapshot.new(
    "queue", 0_i64, 5000_i64, 20_i64, 65536_i64, true, "session", 8_i64, 32_i64, 1_048_576_i64,
    true, debounce_ms, 16_i64, max_wait_ms)
end

def steer_env(max_wait_ms : Int64 = 30_000)
  dir = Path[Dir.tempdir, "sebas-steer-spec", Random::Secure.hex(4)]
  FileUtils.mkdir_p(dir)
  store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
  registry = ::Sebas::Sessions::Scheduling::TurnRegistry.new
  center = ::Sebas::Sessions::Scheduling::SteerCenter.new(store, registry,
    ->(_session : String) { steer_test_policy(max_wait_ms) })
  {store, registry, center, dir}
end

module Sebas
  describe "busy steer（M4.5-WP4）" do
    it "TurnRegistry：generation 单调递增，注销仅匹配 turn 生效，比对三元组" do
      _store, registry, _center, _dir = steer_env
      session = "agent:main:acc:email:s1@example.com"
      lease1 = registry.register(session, "turn:a")
      lease2 = registry.register(session, "turn:b")
      lease2.generation.should eq(lease1.generation + 1) # 每注册新 turn 递增
      registry.lease(session).should eq(lease2)

      registry.unregister(session, "turn:stale") # 迟到结束不清新 lease
      registry.lease(session).should eq(lease2)
      registry.unregister(session, "turn:b")
      registry.lease(session).should be_nil

      registry.matches?(session, "turn:a", lease1.generation).should be_false # 已换代
      registry.register(session, "turn:c")
      lease3 = registry.lease(session).should_not be_nil
      registry.matches?(session, lease3.as(::Sebas::Sessions::Scheduling::TurnLease).turn_id,
        lease3.as(::Sebas::Sessions::Scheduling::TurnLease).generation).should be_true
    end

    it "submit：steer 禁用 rejected；空 payload rejected；无活跃 turn 落库即 queued" do
      store, registry, center, _dir = steer_env
      disabled = ::Sebas::Sessions::Scheduling::SteerCenter.new(store, registry,
        ->(_session : String) { ::Sebas::Sessions::Scheduling::PolicySnapshot.new(
          "queue", 0_i64, 5000_i64, 20_i64, 65536_i64, true, "session", 8_i64, 32_i64, 1_048_576_i64,
          false, 300_i64, 16_i64, 30_000_i64) })
      session = "agent:main:acc:email:s2@example.com"

      receipt = disabled.submit(session, "先查数据库")
      receipt.status.to_s.should eq("rejected")
      receipt.reason.should eq("steer disabled")

      empty = center.submit(session, "   ")
      empty.status.to_s.should eq("rejected")
      empty.reason.should eq("empty payload")

      queued = center.submit(session, "换成查 API")
      queued.status.to_s.should eq("queued")
      queued.reason.should eq("no_active_turn")
      row = store.session_steers(session, "queued").first
      row.reason.should eq("no_active_turn")
      # rejected 也落库留审计（全状态回执）
      store.session_steers(session, "rejected").size.should eq(2)
      store.close
    end

    it "pending 上限：accepted 堆积达 steer.max_pending_messages → rejected 显式回执（§4.4 不静默覆盖）" do
      store, registry, center, _dir = steer_env
      session = "agent:main:acc:email:s8@example.com"
      registry.register(session, "turn:t9")
      # 测试策略上限 16：灌 16 条 accepted 后第 17 条 rejected
      16.times { center.submit(session, "纠偏 #{Random::Secure.hex(2)}") }
      store.session_steers(session, "accepted").size.should eq(16)
      overflow = center.submit(session, "第 17 条")
      overflow.status.to_s.should eq("rejected")
      overflow.reason.should eq("pending limit exceeded")
      store.session_steers(session, "accepted").size.should eq(16)
      store.close
    end

    it "submit 绑定活跃 lease → accepted；显式旧 generation → queued(generation_mismatch)" do
      store, registry, center, _dir = steer_env
      session = "agent:main:acc:email:s3@example.com"
      lease = registry.register(session, "turn:t1")

      pending = center.submit(session, "改用中文回答")
      pending.status.to_s.should eq("accepted")
      pending.target_turn_id.should eq("turn:t1")
      pending.target_generation.should eq(lease.generation)
      store.session_steers(session, "accepted").size.should eq(1)

      # 显式 turn 与活跃不一致（优先判 turn）
      stale_turn = center.submit(session, "迟到纠偏", target_turn_id: "turn:t0",
        target_generation: lease.generation - 1)
      stale_turn.status.to_s.should eq("queued")
      stale_turn.reason.should eq("turn_mismatch")

      # turn 一致仅 generation 旧
      stale_gen = center.submit(session, "旧世代纠偏", target_generation: lease.generation - 1)
      stale_gen.status.to_s.should eq("queued")
      stale_gen.reason.should eq("generation_mismatch")
      store.session_steers(session, "queued").size.should eq(2)
      store.close
    end

    it "drain：轮边界按接收顺序注入（多条组一批），CAS injected + transcript 标记；旧 generation 不注入" do
      store, registry, center, _dir = steer_env
      session = "agent:main:acc:email:s4@example.com"
      lease = registry.register(session, "turn:t2")
      center.submit(session, "第一条纠偏")
      center.submit(session, "第二条纠偏")

      # 迟到 drain：generation 不匹配（旧 turn 调用）→ 保守不注入
      center.drain(session, "turn:t2", lease.generation - 1).should be_empty
      store.session_steers(session, "accepted").size.should eq(2)

      injected = center.drain(session, "turn:t2", lease.generation)
      injected.size.should eq(2)
      injected[0].should contain("第一条纠偏")
      injected[1].should contain("第二条纠偏")
      store.session_steers(session, "accepted").should be_empty
      store.session_steers(session, "injected").size.should eq(2)
      # 注入证明：transcript 独立 user 消息附 turn/generation 元数据（审计可重放）
      markers = store.transcripts(session).select(&.content.starts_with?("[steer "))
      markers.size.should eq(2)
      markers.first.content.should contain("turn=turn:t2 gen=#{lease.generation}")
      store.close
    end

    it "flush_to_queue：turn 结束未注入 pending 全转 queued（按接收顺序返回）" do
      store, registry, center, _dir = steer_env
      session = "agent:main:acc:email:s5@example.com"
      registry.register(session, "turn:t3")
      center.submit(session, "迟到一")
      center.submit(session, "迟到二")

      downgraded = center.flush_to_queue(session, "turn:t3")
      downgraded.map(&.payload).should eq(["迟到一", "迟到二"])
      downgraded.map(&.steer_id).size.should eq(2) # 带 steer_id 供合成事件幂等
      store.session_steers(session, "accepted").should be_empty
      store.session_steers(session, "queued").size.should eq(2)
      store.close
    end

    it "expire_due：accepted 超 max_wait_ms 转 queued（不等 turn 边界，注入时钟）" do
      dir = Path[Dir.tempdir, "sebas-steer-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir)
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      registry = ::Sebas::Sessions::Scheduling::TurnRegistry.new
      clock = ::Time.utc # 对齐 store 落库时钟（created_at 取真实 now）
      center = ::Sebas::Sessions::Scheduling::SteerCenter.new(store, registry,
        ->(_session : String) { steer_test_policy(max_wait_ms: 30_000) }, now: -> { clock })
      session = "agent:main:acc:email:s6@example.com"
      registry.register(session, "turn:t4")
      center.submit(session, "等不及的纠偏")

      center.expire_due # 未超时：保持 accepted
      store.session_steers(session, "accepted").size.should eq(1)

      clock = clock + 1.minute
      center.expire_due
      store.session_steers(session, "accepted").should be_empty
      row = store.session_steers(session, "queued").first
      row.reason.should eq("max_wait exceeded")
      store.close
    end

    it "recover_unconfirmed：injected 无 transcript 标记 → queued(unknown_not_injected)；有标记保持" do
      store, registry, center, _dir = steer_env
      session = "agent:main:acc:email:s7@example.com"
      lease = registry.register(session, "turn:t5")
      center.submit(session, "崩溃前的纠偏")
      confirmed = center.submit(session, "已注入的纠偏")

      # 模拟崩溃窗口：一行 CAS injected 但 transcript 未落标（unknown）；
      # 另一行经 drain 完整注入（CAS + 落标）
      row = store.session_steers(session, "accepted").first
      store.transition_session_steer(row.steer_id, ::Sebas::Sessions::Scheduling::SteerStatus::Accepted, ::Sebas::Sessions::Scheduling::SteerStatus::Injected)
      center.drain(session, "turn:t5", lease.generation)
      store.session_steers(session, "injected").size.should eq(2)

      # 再补一条 accepted 未注入行（§5.2：重启后转 queued 后续批次）
      center.submit(session, "重启时的纠偏")
      store.session_steers(session, "accepted").size.should eq(1)

      center.recover_unconfirmed
      rows = store.session_steers(session)
      unknown = rows.find { |candidate| candidate.reason == "unknown_not_injected" }.should_not be_nil
      unknown.as(::Sebas::Platform::Store::Store::SessionSteerRow).steer_id.should eq(row.steer_id)
      kept = rows.find { |candidate| candidate.steer_id == confirmed.steer_id }.should_not be_nil
      kept.as(::Sebas::Platform::Store::Store::SessionSteerRow).status.should eq("injected")
      recovered = rows.find { |candidate| candidate.reason == "recovery_no_active_turn" }.should_not be_nil
      recovered.as(::Sebas::Platform::Store::Store::SessionSteerRow).status.should eq("queued")
      store.close
    end
  end
end
