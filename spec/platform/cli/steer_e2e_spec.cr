require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/providers/fake_provider"
require "../../support/gateway_spec_helper"
require "../../support/fake_smtp_server"
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
      # 不进 turn：无 turn task、无 user transcript（纠偏正文只落 steer 表）
      expect_raises(DB::NoResultsError) { gateway.store.task("turn:evt-steer-1") }
      gateway.store.transcripts(session).should be_empty
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
