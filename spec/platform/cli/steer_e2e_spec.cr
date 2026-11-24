require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/providers/fake_provider"
require "../../support/gateway_spec_helper"
require "../../support/fake_smtp_server"

# 脚本化 Provider（活跃 turn 注入 e2e）：按调用次序返回预设响应
class SteerE2EProvider < ::Sebas::Providers::Provider
  @scripts : Array(String)
  @count = 0
  @delay_ms : Int32
  getter seen_messages : Array(Array(::Sebas::Providers::Message))

  def initialize(model : String, scripts : Array(String), @delay_ms = 0)
    super(model)
    @scripts = scripts
    @seen_messages = [] of Array(::Sebas::Providers::Message)
  end

  def complete(messages : Array(::Sebas::Providers::Message)) : ::Sebas::Providers::Completion
    sleep @delay_ms.milliseconds if @delay_ms > 0 # 拉长 turn 活跃窗口（/steer 时序确定性）
    @seen_messages << messages
    idx = @count
    @count += 1
    ::Sebas::Providers::Completion.new(@scripts[idx]? || "script exhausted", nil)
  end
end

require "../../../src/channels/email/adapter"

# busy steer e2e（M4.5-WP4）：显式 /steer 命令入口——普通聊天正文不猜纠偏意图
module Sebas
  describe "/steer 命令（M4.5-WP4）" do
    it "steer 启用：/steer 提交落库 queued（无活跃 turn），不创建 turn task、不发模型请求" do
      dir = gateway_tmp_dir("steer-e2e")
      config = ::Sebas::Platform::Config::Loader.from_content(<<-YAML
        channels:
          email:
            accounts:
              - id: test-acc
                platform: 127.0.0.1
                receive: imap-idle
                smtp: { port: 2525, tls: none }
                credentials: { user: me@example.com, password: p }
        agents:
          main:
            model: fake/chat
            session:
              steer:
                enabled: true
        bindings:
          - { channel: email, account: test-acc, peer: "*", agent: main }
        YAML
      )
      provider = ::Sebas::Providers::FakeProvider.new("fake/chat", ["ok"])
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        provider
      end
      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-steer-1", "email", "test-acc", "alice@example.com", "/steer 改用中文回答"
      ))
      gateway.run
      ok = wait_for { gateway.store.intent_status("evt-steer-1") == "done" }
      gateway.shutdown
      ok.should be_true

      session = "agent:main:test-acc:email:alice@example.com"
      steers = gateway.store.session_steers(session)
      steers.size.should eq(1)
      steers.first.status.should eq("queued")
      steers.first.reason.should eq("no_active_turn")
      steers.first.payload.should eq("改用中文回答")
      # 原事件不进 turn（纠偏不占 turn task）；queued 立即合成投递组后续
      # 批次（不丢消息）——合成 turn 消费 [steer replay] 内容
      expect_raises(DB::NoResultsError) { gateway.store.task("turn:evt-steer-1") }
      gateway.store.task("turn:steer-dispatch-steer-evt-steer-1").kind.should eq("turn")
      gateway.store.transcripts(session).any?(&.content.starts_with?("[steer replay]")).should be_true
    end

    it "活跃 turn 进行中 /steer：注入下一次模型请求（短路直达，不被批次卡死）" do
      dir = gateway_tmp_dir("steer-inject")
      config = ::Sebas::Platform::Config::Loader.from_content(<<-YAML
        channels:
          email:
            accounts:
              - id: test-acc
                platform: 127.0.0.1
                receive: imap-idle
                smtp: { port: 2525, tls: none }
                credentials: { user: me@example.com, password: p }
        agents:
          main:
            model: fake/chat
            session:
              steer:
                enabled: true
        bindings:
          - { channel: email, account: test-acc, peer: "*", agent: main }
        YAML
      )
      # 脚本化 provider：第一轮工具调用（触发 ReAct 第二轮），第二轮终答
      provider = SteerE2EProvider.new("fake/chat", [
        "checking\n```json\n{\"tool\": \"memory.save\", \"args\": {\"key\": \"st\", \"body\": \"r1\"}}\n```",
        "final after steer",
      ], delay_ms: 400)
      smtp = FakeSmtpServer.new
      smtp.serve
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        provider
      end
      gateway.channels.register(::Sebas::Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))
      # 普通 turn 先入队；等 turn 真正开始（lease 注册）再提交 /steer——
      # 时序确定性（否则提交即 queued 立即合成投递，注入路径覆盖不到）
      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-inject-1", "email", "test-acc", "carol@example.com", "run tool round"
      ))
      gateway.run
      session = "agent:main:test-acc:email:carol@example.com"
      lease_ready = wait_for(10.seconds) { !gateway.steer_registry.lease(session).nil? }
      lease_ready.should be_true
      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-inject-2", "email", "test-acc", "carol@example.com", "/steer 改用中文"
      ))
      # 等 steer 注入并进入第二轮模型请求（shutdown 过早会截断 complete）
      ok = wait_for(15.seconds) { provider.seen_messages.size >= 2 }
      gateway.shutdown
      ok.should be_true
      gateway.store.session_steers(session, "injected").size.should eq(1) # drain CAS 已落

      steers = gateway.store.session_steers(session)
      steers.size.should eq(1)
      steers.first.steer_id.should eq("steer-evt-inject-2") # event_id 派生
      steers.first.status.should eq("injected")             # 真实注入（drain CAS）
      # 注入证明：transcript 有标记行 + 第二轮模型请求含 steer 文本
      gateway.store.transcripts(session).any?(&.content.starts_with?("[steer steer-evt-inject-2")).should be_true
      second_round = provider.seen_messages[1].map(&.content)
      second_round.any?(&.starts_with?("[steer steer-evt-inject-2]")).should be_true
    end

    it "queued steer 消费：turn 结束 flush 后合成事件重走 admission 组后续批次" do
      dir = gateway_tmp_dir("steer-consume")
      config = ::Sebas::Platform::Config::Loader.from_content(<<-YAML
        channels:
          email:
            accounts:
              - id: test-acc
                platform: 127.0.0.1
                receive: imap-idle
                smtp: { port: 2525, tls: none }
                credentials: { user: me@example.com, password: p }
        agents:
          main:
            model: fake/chat
            session:
              batch_mode: queue
              steer:
                enabled: true
        bindings:
          - { channel: email, account: test-acc, peer: "*", agent: main }
        YAML
      )
      provider = ::Sebas::Providers::FakeProvider.new("fake/chat", ["ok", "ok"])
      smtp = FakeSmtpServer.new
      smtp.serve
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        provider
      end
      gateway.channels.register(::Sebas::Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))
      # 第一条：单轮直答 turn（无工具边界）；第二条：/steer（无活跃 turn → queued）
      # flush 后合成事件重走 admission → 第二个 turn 处理 [steer replay] 内容
      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-cons-1", "email", "test-acc", "dave@example.com", "quick answer"
      ))
      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-cons-2", "email", "test-acc", "dave@example.com", "/steer 后续纠偏"
      ))
      gateway.run
      ok = wait_for { gateway.store.intent_status("steer-dispatch-steer-evt-cons-2") == "done" }
      gateway.shutdown
      ok.should be_true

      session = "agent:main:test-acc:email:dave@example.com"
      steers = gateway.store.session_steers(session, "queued")
      steers.size.should eq(1)
      steers.first.reason.should eq("no_active_turn")
      # 合成事件成为第二个 turn（queued 有消费方）
      gateway.store.task("turn:steer-dispatch-steer-evt-cons-2").kind.should eq("turn")
      gateway.store.transcripts(session).any?(&.content.starts_with?("[steer replay]")).should be_true
    end

    it "steer 禁用（默认）：/steer rejected 落库，普通消息照常走 turn" do
      dir = gateway_tmp_dir("steer-disabled")
      config = gw_test_config
      smtp = FakeSmtpServer.new
      smtp.serve
      provider = ::Sebas::Providers::FakeProvider.new("fake/chat", ["ok"])
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        provider
      end
      gateway.channels.register(::Sebas::Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))
      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-steer-2", "email", "test-acc", "bob@example.com", "/steer rejected please"
      ))
      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-steer-3", "email", "test-acc", "bob@example.com", "normal chat"
      ))
      gateway.run
      ok = wait_for { gateway.store.intent_status("evt-steer-3") == "done" }
      gateway.shutdown
      ok.should be_true

      session = "agent:main:test-acc:email:bob@example.com"
      steers = gateway.store.session_steers(session)
      steers.size.should eq(1)
      steers.first.status.should eq("rejected")
      steers.first.reason.should eq("steer disabled")
      # 普通消息照常进 turn（steer 命令不占 turn，普通正文不被误判）
      gateway.store.task("turn:evt-steer-3").kind.should eq("turn")
      gateway.store.transcripts(session).map(&.role).should eq(["user", "agent"])
    end
  end
end
