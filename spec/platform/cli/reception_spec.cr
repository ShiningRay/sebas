require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/providers/fake_provider"
require "../../support/gateway_spec_helper"
require "../../support/fake_smtp_server"

module Sebas
  describe "前台接待（M4.3-WP3，Q8 拆分第一块）" do
    it "无 binding 匿名消息获前台应答并可转介（Session 藏而不删）" do
      dir = gateway_tmp_dir("reception")
      # 前台配置：agents.reception（只读默认档）
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
          main: { model: fake/chat }
          reception: { model: fake/reception }
        bindings:
          - { channel: email, account: test-acc, peer: "known@example.com", agent: main }
        YAML
      )
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        ::Sebas::Providers::FakeProvider.new(agent.model,
          agent.model == "fake/reception" ? ["front desk: I can only look things up; ask the operator to route you"] : ["main answer"])
      end
      smtp = FakeSmtpServer.new
      smtp.serve
      gateway.channels.register(::Sebas::Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))

      # 匿名 peer（无 binding 匹配）→ 前台接待
      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-recept-1", "email", "test-acc", "stranger@example.com", "hello?"
      ))
      gateway.run
      ok = wait_for { gateway.store.intent_status("evt-recept-1") == "done" }
      gateway.shutdown
      ok.should be_true

      # 前台会话键（匿名/临时包装，Session 藏而不删——transcript 照常落）
      front_session = "agent:reception:test-acc:email:stranger@example.com"
      front_contents = gateway.store.transcripts(front_session).map(&.content)
      front_contents.should contain("hello?")
      front_contents.last.should contain("front desk")
    end

    it "已知 binding 消息仍路由 main（前台不劫持）" do
      dir = gateway_tmp_dir("reception-known")
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
          main: { model: fake/chat }
          reception: { model: fake/reception }
        bindings:
          - { channel: email, account: test-acc, peer: "known@example.com", agent: main }
        YAML
      )
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        ::Sebas::Providers::FakeProvider.new(agent.model, ["main answer"])
      end
      smtp = FakeSmtpServer.new
      smtp.serve
      gateway.channels.register(::Sebas::Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))

      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-known-1", "email", "test-acc", "known@example.com", "known peer"
      ))
      gateway.run
      ok = wait_for { gateway.store.intent_status("evt-known-1") == "done" }
      gateway.shutdown
      ok.should be_true
      main_session = "agent:main:test-acc:email:known@example.com"
      gateway.store.transcripts(main_session).last.content.should eq("main answer")
    end

    it "无前台配置保持 fail-closed 丢弃（回归：M0 行为 + 审计保留）" do
      dir = gateway_tmp_dir("reception-none")
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
          main: { model: fake/chat }
        bindings:
          - { channel: email, account: test-acc, peer: "known@example.com", agent: main }
        YAML
      )
      provider_ran = false
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        provider_ran = true
        ::Sebas::Providers::FakeProvider.new("fake", ["should not run"])
      end
      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-recept-none", "email", "test-acc", "stranger@example.com", "hello?"
      ))
      gateway.run
      sleep 500.milliseconds
      gateway.shutdown
      # 无前台配置：匿名消息被丢弃（无前台会话、无 intent、provider 未执行）
      front_session = "agent:reception:test-acc:email:stranger@example.com"
      gateway.store.transcripts(front_session).should be_empty
      gateway.store.intent_status("evt-recept-none").should be_nil
      provider_ran.should be_false
    end
  end
end
