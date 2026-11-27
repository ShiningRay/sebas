require "spec"
require "http"
require "json"
require "../../src/channels/telegram/adapter"
require "../../src/platform/store/store"
require "../../src/platform/bus/bus"
require "../support/fake_bot_api_server"
require "../support/telegram_spec_helpers"

# Telegram store 层与恢复语义用例（M3-WP8，自 telegram_spec.cr 拆出守 400 行）：
# 消费者确认链（窗口 C）、全量补确认、两账号隔离、恢复扫描、非消息类 update。
module Sebas
  describe "telegram store & recovery (M3-WP8)" do
    it "恢复扫描：dispatched=false 重投（event_id 同值）；dispatched=true 与 dead_letter 不选中" do
      store = build_store("recover")
      server = FakeBotApiServer.new
      server.serve
      begin
        clock = FakeClock.new(::Time.utc(2026, 11, 27, 12, 0, 0))
        tg, bus = build_tg_poll(store, server, "acct", clock)
        server.queue_updates([make_update(40, "555", "lost-a"), make_update(41, "555", "lost-b")])
        tg.poll_once
        bus.receive?(1.second)
        bus.receive?(1.second)

        rows = store.pending_telegram_updates("acct")
        rows.size.should eq(2)
        store.mark_telegram_dispatched(rows.first.event_id) # 窗口 B：消费者已确认
        store.mark_telegram_dead_letter(rows[1].event_id)   # 死信

        # 重启恢复扫描：仅未确认且非死信行被重投
        tg2, bus2 = build_tg_poll(store, server, "acct", clock)
        tg2.recover_pending.should eq(0) # 唯一 pending 行已置位，死信被排除
        bus2.receive?(0.2.seconds).should be_nil

        # 未确认行（模拟窗口 B 残留）重投且 event_id 与原投递同值
        server.queue_updates([make_update(42, "555", "window-b")])
        tg.poll_once
        original = store.pending_telegram_updates("acct").first.event_id
        tg2.recover_pending.should eq(1)
        msg = bus2.receive?(1.second)
        msg.should_not be_nil
        msg.as(::Sebas::Platform::Bus::InboundMessage).event_id.should eq(original)
      ensure
        server.close
        store.close
      end
    end

    it "非消息类 update：落库即置 dispatched、不入总线、offset 照常推进" do
      store = build_store("nonmsg")
      server = FakeBotApiServer.new
      server.serve
      begin
        clock = FakeClock.new(::Time.utc(2026, 11, 27, 12, 0, 0))
        tg, bus = build_tg_poll(store, server, "acct", clock)
        server.queue_updates([make_non_message_update(50)])
        tg.poll_once.should eq(::Sebas::Channels::Telegram::LongPoll::Outcome::ActiveAdvanced)
        store.pending_telegram_updates("acct").size.should eq(0) # 已直接置位
        store.telegram_account_state("acct").persisted_offset.should eq(50)
        bus.receive?(0.2.seconds).should be_nil
      ensure
        server.close
        store.close
      end
    end

    it "消费者确认链：mark 直接置位；confirm 仅在 intent done/dispatched 时置位（窗口 C）" do
      store = build_store("confirm")
      server = FakeBotApiServer.new
      server.serve
      begin
        clock = FakeClock.new(::Time.utc(2026, 11, 27, 12, 0, 0))
        tg, _bus = build_tg_poll(store, server, "acct", clock)
        server.queue_updates([make_update(60, "555", "c-window")])
        tg.poll_once
        event_id = store.pending_telegram_updates("acct").first.event_id

        # intent 不存在（record_intent 失败场景）：confirm 保留 false（交调度器扩展 #252）
        store.confirm_telegram_dispatch(event_id).should be_false
        store.telegram_dispatched?(event_id).should be_false

        # intent pending（record_intent 成功、turn 未完成）：仍不补确认
        store.record_intent(event_id, "message", "{}")
        store.confirm_telegram_dispatch(event_id).should be_false
        store.telegram_dispatched?(event_id).should be_false

        # intent dispatched（process_message 主路径）：补确认置位
        store.finish_intent(event_id, "dispatched")
        store.confirm_telegram_dispatch(event_id).should be_true
        store.telegram_dispatched?(event_id).should be_true
      ensure
        server.close
        store.close
      end
    end

    it "全量补确认扫描（recover 后统一收敛窗口 C 存量行）" do
      store = build_store("confirmall")
      server = FakeBotApiServer.new
      server.serve
      begin
        clock = FakeClock.new(::Time.utc(2026, 11, 27, 12, 0, 0))
        tg, _bus = build_tg_poll(store, server, "acct", clock)
        server.queue_updates([make_update(61, "555", "m1"), make_update(62, "555", "m2")])
        tg.poll_once
        rows = store.pending_telegram_updates("acct")
        store.record_intent(rows[0].event_id, "message", "{}")
        store.finish_intent(rows[0].event_id, "done")
        # rows[1] 无 intent（record_intent 失败）——不补确认

        store.confirm_telegram_dispatches.should eq(1)
        store.telegram_dispatched?(rows[0].event_id).should be_true
        store.telegram_dispatched?(rows[1].event_id).should be_false
      ensure
        server.close
        store.close
      end
    end

    it "两账号同时 online 不串扰：状态按 account_id 隔离" do
      store = build_store("multiacct")
      server = FakeBotApiServer.new
      server.serve
      begin
        clock = FakeClock.new(::Time.utc(2026, 11, 27, 12, 0, 0))
        tg_a, bus_a = build_tg_poll(store, server, "acct-a", clock)
        tg_b, bus_b = build_tg_poll(store, server, "acct-b", clock)
        server.queue_updates([make_update(70, "111", "for-a")])
        tg_a.poll_once
        server.queue_updates([make_update(71, "222", "for-b")])
        tg_b.poll_once

        store.telegram_account_state("acct-a").persisted_offset.should eq(70)
        store.telegram_account_state("acct-b").persisted_offset.should eq(71)
        store.pending_telegram_updates("acct-a").size.should eq(1)
        store.pending_telegram_updates("acct-b").size.should eq(1)
        bus_a.receive?(1.second).as(::Sebas::Platform::Bus::InboundMessage).content.should eq("for-a")
        bus_b.receive?(1.second).as(::Sebas::Platform::Bus::InboundMessage).content.should eq("for-b")
        bus_a.receive?(0.1.seconds).should be_nil # A 的总线无 B 的消息
      ensure
        server.close
        store.close
      end
    end
  end
end
