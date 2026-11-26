require "spec"
require "http"
require "json"
require "../../src/channels/telegram/adapter"
require "../support/fake_bot_api_server"
require "../support/telegram_spec_helpers"

module Sebas
  describe "telegram channel (M3-WP8)" do
    it "event_id 派生确定性：同输入同值、内容不同同 ID 异值（提案 §4.2）" do
      a = make_update(100, "555", "hello", 1)
      b = make_update(100, "555", "hello", 1)
      c = make_update(100, "555", "world", 2)
      e1 = ::Sebas::Channels::Telegram::BotApi.parse_update(a).event_id("acct")
      e2 = ::Sebas::Channels::Telegram::BotApi.parse_update(b).event_id("acct")
      e3 = ::Sebas::Channels::Telegram::BotApi.parse_update(c).event_id("acct")
      e1.should eq(e2)
      e1.should_not eq(e3)
      e1.should start_with("tg:acct:")
    end

    it "BotApi getUpdates 解析 + sendMessage 返回 message_id（mock server 收发全通）" do
      server = FakeBotApiServer.new
      server.serve
      begin
        api = ::Sebas::Channels::Telegram::BotApi.new(server.token, http: server.client)
        server.queue_updates([make_update(7, "555", "hi")])
        updates = api.get_updates(nil)
        updates.size.should eq(1)
        updates.first.update_id.should eq(7)
        updates.first.chat_id.should eq("555")
        updates.first.text.should eq("hi")
        api.send_message("555", "reply").should eq("4242")
        server.messages.size.should eq(1)
        server.messages.first[:chat_id].should eq("555")
      ensure
        server.close
      end
    end

    it "BotApi 错误响应（ok=false）抛 BotApiError 携带 error_code" do
      server = FakeBotApiServer.new
      server.serve
      begin
        api = ::Sebas::Channels::Telegram::BotApi.new(server.token, http: server.client)
        server.queue_error(429, "Too Many Requests: retry after 3")
        expect_raises(::Sebas::Channels::Telegram::BotApiError, "Too Many Requests") do
          api.get_updates(nil)
        end
      ensure
        server.close
      end
    end

    it "活跃窗口端到端：落库 dispatched=false → offset 推进 → 入总线（写入顺序纪律）" do
      store = build_store("active")
      server = FakeBotApiServer.new
      server.serve
      begin
        clock = FakeClock.new(::Time.utc(2026, 11, 27, 12, 0, 0))
        tg, bus = build_tg_poll(store, server, "acct-a", clock)
        server.queue_updates([make_update(11, "555", "hello")])
        tg.poll_once.should eq(::Sebas::Channels::Telegram::LongPoll::Outcome::ActiveAdvanced)

        pending = store.pending_telegram_updates("acct-a")
        pending.size.should eq(1)
        pending.first.update_id.should eq(11)
        pending.first.dispatched.should be_false # 生产者不置位，待消费者确认
        store.telegram_account_state("acct-a").persisted_offset.should eq(11)
        store.telegram_account_state("acct-a").last_update_at.should eq(clock.call.to_rfc3339)

        msg = bus.receive?(1.second)
        msg.should_not be_nil
        message = msg.as(::Sebas::Platform::Bus::InboundMessage)
        message.channel_type.should eq("telegram")
        message.account_id.should eq("acct-a")
        message.peer.should eq("555")
        message.content.should eq("hello")
        message.event_id.should eq(pending.first.event_id)
      ensure
        server.close
        store.close
      end
    end

    it "空响应不刷新 last_update_at（连续空闲须能达 6 天阈值）" do
      store = build_store("emptyresp")
      server = FakeBotApiServer.new
      server.serve
      begin
        clock = FakeClock.new(::Time.utc(2026, 11, 27, 12, 0, 0))
        tg, _bus = build_tg_poll(store, server, "acct", clock)
        tg.poll_once.should eq(::Sebas::Channels::Telegram::LongPoll::Outcome::Empty)
        store.telegram_account_state("acct").last_update_at.should be_nil
        clock.now = ::Time.utc(2026, 11, 27, 13, 0, 0)
        tg.poll_once.should eq(::Sebas::Channels::Telegram::LongPoll::Outcome::Empty)
        store.telegram_account_state("acct").last_update_at.should be_nil
      ensure
        server.close
        store.close
      end
    end

    it "单调排重：update_id ≤ persisted_offset 跳过，指纹唯一索引兜底重推" do
      store = build_store("mono")
      server = FakeBotApiServer.new
      server.serve
      begin
        clock = FakeClock.new(::Time.utc(2026, 11, 27, 12, 0, 0))
        tg, bus = build_tg_poll(store, server, "acct", clock)
        server.queue_updates([make_update(20, "555", "one")])
        tg.poll_once
        bus.receive?(1.second) # 清空总线

        # Telegram 重推同一条（offset 未确认场景）：offset=20 → 请求 21，服务端
        # 不会返回 20；此处模拟指纹兜底——同内容不同 update_id 直接被单调排重跳过
        server.queue_updates([make_update(20, "555", "one"), make_update(21, "555", "two")])
        tg.poll_once
        bus.receive?(1.second).should_not be_nil # 21 入总线
        bus.receive?(0.1.seconds).should be_nil  # 20 不重投
        # 同 ID 重推不重复落库：总行数恰为 2（20 未确认 pending + 21 新行）
        store.pending_telegram_updates("acct").map(&.update_id).sort!.should eq([20, 21])
        store.telegram_account_state("acct").persisted_offset.should eq(21)
      ensure
        server.close
        store.close
      end
    end

    it "崩溃窗口 A（Step 1 后、Step 2 前重启）：重推同 update 不重复落库、照常入总线" do
      store = build_store("windowa")
      server = FakeBotApiServer.new
      server.serve
      begin
        clock = FakeClock.new(::Time.utc(2026, 11, 27, 12, 0, 0))
        update = make_update(30, "555", "persisted")
        parsed = ::Sebas::Channels::Telegram::BotApi.parse_update(update)
        # 真实窗口 A 现场：Step 1 已落库（dispatched=false）、Step 2 offset 未推进
        store.persist_telegram_update(parsed.event_id("acct"), "acct", 30,
          parsed.content_fingerprint, update.to_json)
        tg, bus = build_tg_poll(store, server, "acct", clock)

        # 重启后 Telegram 重推同一条（offset 未确认 → 服务端重投）
        server.queue_updates([update])
        tg.poll_once.should eq(::Sebas::Channels::Telegram::LongPoll::Outcome::ActiveAdvanced)
        # 冲突行 dispatched=false → Step 3 照常执行（不视为失败、不重复落库）
        store.pending_telegram_updates("acct").size.should eq(1) # 同 event_id 主键，不产生第二行
        store.telegram_account_state("acct").persisted_offset.should eq(30)
        msg = bus.receive?(1.second)
        msg.should_not be_nil
        msg.as(::Sebas::Platform::Bus::InboundMessage).content.should eq("persisted")
      ensure
        server.close
        store.close
      end
    end

    it "崩溃窗口 A 且行已 dispatched：重推 Step 3 跳过，offset 照常推进" do
      store = build_store("windowad")
      server = FakeBotApiServer.new
      server.serve
      begin
        clock = FakeClock.new(::Time.utc(2026, 11, 27, 12, 0, 0))
        update = make_update(31, "555", "done-msg")
        parsed = ::Sebas::Channels::Telegram::BotApi.parse_update(update)
        # 窗口 A 现场 + 消费者已确认（dispatched=true）：offset 未推进、行已投过
        store.persist_telegram_update(parsed.event_id("acct"), "acct", 31,
          parsed.content_fingerprint, update.to_json)
        store.mark_telegram_dispatched(parsed.event_id("acct"))

        tg, bus = build_tg_poll(store, server, "acct", clock)
        server.queue_updates([update])
        tg.poll_once.should eq(::Sebas::Channels::Telegram::LongPoll::Outcome::ActiveAdvanced)
        bus.receive?(0.2.seconds).should be_nil                             # 已投过，不重复入总线
        store.telegram_account_state("acct").persisted_offset.should eq(31) # Step 2 照常
      ensure
        server.close
        store.close
      end
    end

    it "空闲 ≥6 天进入重置模式：无 offset 轮询；退出同事务写 offset 与 reset_mode" do
      store = build_store("reset")
      server = FakeBotApiServer.new
      server.serve
      begin
        clock = FakeClock.new(::Time.utc(2026, 12, 2, 12, 0, 0))
        store.ensure_telegram_account("acct")
        # 上次收到 update 是 5 天前（活跃期结束），空闲未满 6 天
        store.touch_telegram_last_update("acct", (::Time.utc(2026, 12, 2, 12, 0, 0) - 5.days).to_rfc3339)
        store.advance_telegram_offset("acct", 500)

        tg, bus = build_tg_poll(store, server, "acct", clock)
        tg.reset_mode?.should be_false
        # 空闲 7 天（≥6 天）进重置模式
        clock.now = ::Time.utc(2026, 12, 9, 12, 0, 0)
        tg.reset_mode?.should be_true
        # 重置模式轮询：请求不带 offset（拉未确认全集）
        server.queue_updates([make_update(3, "555", "after-reset")]) # 小 ID（重置后随机位置）
        tg.poll_once.should eq(::Sebas::Channels::Telegram::LongPoll::Outcome::ResetExited)
        server.recorded_offsets.last.should be_nil

        # 同事务退出：offset=本轮最大 update_id、reset_mode=false
        state = store.telegram_account_state("acct")
        state.persisted_offset.should eq(3)
        state.reset_mode.should be_false
        bus.receive?(1.second).should_not be_nil # 重置模式收到的 update 已入总线
      ensure
        server.close
        store.close
      end
    end

    it "重置模式空轮询不退出、不刷新 last_update_at（提案 §4.2 退出条件）" do
      store = build_store("resetempty")
      server = FakeBotApiServer.new
      server.serve
      begin
        clock = FakeClock.new(::Time.utc(2026, 12, 4, 12, 0, 0))
        store.ensure_telegram_account("acct")
        store.enter_telegram_reset_mode("acct")

        tg, _bus = build_tg_poll(store, server, "acct", clock)
        tg.poll_once.should eq(::Sebas::Channels::Telegram::LongPoll::Outcome::Empty)
        tg.poll_once.should eq(::Sebas::Channels::Telegram::LongPoll::Outcome::Empty)
        server.recorded_offsets.size.should eq(2)
        server.recorded_offsets.each(&.should(be_nil)) # 连续无 offset 轮询
        store.telegram_account_state("acct").reset_mode.should be_true
        store.telegram_account_state("acct").persisted_offset.should eq(0)
        store.telegram_account_state("acct").last_update_at.should be_nil
      ensure
        server.close
        store.close
      end
    end

    it "reset_mode 持久位跨崩溃延续（重启后即便 last_update_at 新近仍无 offset）" do
      store = build_store("resetpersist")
      server = FakeBotApiServer.new
      server.serve
      begin
        clock = FakeClock.new(::Time.utc(2026, 12, 4, 12, 0, 0))
        store.ensure_telegram_account("acct")
        store.enter_telegram_reset_mode("acct")
        # 模拟崩溃前刚刷新过 last_update_at（重置模式收到小 ID 后、落库前崩溃）
        store.touch_telegram_last_update("acct", ::Time.utc(2026, 12, 4, 11, 59, 0).to_rfc3339)

        tg, _bus = build_tg_poll(store, server, "acct", clock)
        tg.reset_mode?.should be_true # 只看 last_update_at 会误判活跃——持久位兜住
        server.queue_updates([] of ::JSON::Any)
        tg.poll_once
        server.recorded_offsets.last.should be_nil
      ensure
        server.close
        store.close
      end
    end

    it "adapter 出站：sendMessage 全链路成功 + 限流桶参数（1/s per chat、30/s 全局）" do
      store = build_store("adapter")
      server = FakeBotApiServer.new
      server.serve
      begin
        account = ::Sebas::Platform::Config::TelegramAccount.from_yaml(
          "id: acct\nbot_token: \"#{server.token}\"\n"
        )
        bus = ::Sebas::Platform::Bus::Bus.new(8)
        adapter = ::Sebas::Channels::Telegram::TelegramChannelAdapter.new(account, bus, store,
          send_api_factory: -> { ::Sebas::Channels::Telegram::BotApi.new(account.bot_token, http: server.client) })
        adapter.channel_type.should eq("telegram")
        adapter.account_id.should eq("acct")

        result = adapter.send("555", "hello bot", "idem-1")
        result.ok?.should be_true
        server.messages.size.should eq(1)
        server.messages.first[:text].should eq("hello bot")

        ::Sebas::Channels::Telegram::TelegramChannelAdapter::PEER_RATE.should eq(1.0)
        ::Sebas::Channels::Telegram::TelegramChannelAdapter::GLOBAL_RATE.should eq(30.0)
      ensure
        server.close
        store.close
      end
    end

    it "adapter send 上游传输失败走错误语义（SendResult.error）" do
      store = build_store("ratelimited")
      server = FakeBotApiServer.new
      server.serve
      begin
        account = ::Sebas::Platform::Config::TelegramAccount.from_yaml(
          "id: acct\nbot_token: \"123:t\"\n"
        )
        bus = ::Sebas::Platform::Bus::Bus.new(8)
        # 不可达端口模拟传输失败路径（BotApiError → SendResult.error）；
        # 经 send_api_factory 注入——出站与 long-poll 不共享 client
        broken = ::Sebas::Channels::Telegram::BotApi.new(account.bot_token, "http://127.0.0.1:1", read_timeout: 2.seconds)
        adapter = ::Sebas::Channels::Telegram::TelegramChannelAdapter.new(account, bus, store,
          send_api_factory: -> { broken })
        result = adapter.send("555", "x")
        result.ok?.should be_false
        result.error.should_not be_nil
      ensure
        server.close
        store.close
      end
    end

    it "send 超长文本按 4096 字符切分多条依次发送" do
      store = build_store("chunk")
      server = FakeBotApiServer.new
      server.serve
      begin
        account = ::Sebas::Platform::Config::TelegramAccount.from_yaml(
          "id: acct\nbot_token: \"#{server.token}\"\n"
        )
        bus = ::Sebas::Platform::Bus::Bus.new(8)
        adapter = ::Sebas::Channels::Telegram::TelegramChannelAdapter.new(account, bus, store,
          send_api_factory: -> { ::Sebas::Channels::Telegram::BotApi.new(account.bot_token, http: server.client) })
        long_text = "字" * 5000
        result = adapter.send("555", long_text)
        result.ok?.should be_true
        server.messages.size.should eq(2)
        server.messages[0][:text].size.should eq(4096)
        server.messages[1][:text].size.should eq(904)
        (server.messages[0][:text] + server.messages[1][:text]).should eq(long_text)
        # 短文本不切分
        adapter.send("555", "short").ok?.should be_true
        server.messages.size.should eq(3)
      ensure
        server.close
        store.close
      end
    end

    it "adapter.start 驱动 run 循环真实轮询（stop 标志语义回归：true=运行）" do
      store = build_store("startloop")
      server = FakeBotApiServer.new
      server.serve
      begin
        account = ::Sebas::Platform::Config::TelegramAccount.from_yaml(
          "id: acct\nbot_token: \"#{server.token}\"\n"
        )
        bus = ::Sebas::Platform::Bus::Bus.new(8)
        adapter = ::Sebas::Channels::Telegram::TelegramChannelAdapter.new(account, bus, store,
          scan_interval: 1.hour, backoff: 10.milliseconds,
          api: ::Sebas::Channels::Telegram::BotApi.new(server.token, http: server.client))
        server.queue_updates([] of ::JSON::Any)
        adapter.start
        # run 循环真实轮询：mock 服务端收到的 getUpdates 请求持续增长
        deadline = Time.instant + 5.seconds
        until server.recorded_offsets.size >= 2
          raise "run loop did not poll (recorded=#{server.recorded_offsets.size})" if Time.instant > deadline
          sleep 10.milliseconds
        end
        adapter.stop
        adapter.health.should eq("online")
      ensure
        server.close
        store.close
      end
    end

    it "BotApi 非回环 api_base_url 拒绝明文 http（bot_token 防明文传输）" do
      expect_raises(ArgumentError, /https/) do
        ::Sebas::Channels::Telegram::BotApi.new("t", "http://relay.example.com:8080")
      end
      # 回环豁免（本机 mock/反代）
      ::Sebas::Channels::Telegram::BotApi.new("t", "http://127.0.0.1:8080")
      ::Sebas::Channels::Telegram::BotApi.new("t", "http://localhost:8080")
    end
  end
end
