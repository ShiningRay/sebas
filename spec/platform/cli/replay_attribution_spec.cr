require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/providers/fake_provider"
require "../../support/gateway_spec_helper"
require "../../support/fake_smtp_server"

# #176 回归：binding 在 intent 落库后变更、进程重启再 replay_unfinished，
# 重放 transcript 仍写入 admission 时的 session_key（binding 热换不影响归属）
module Sebas
  describe "replay 归属保留（#176）" do
    it "binding 变更后重放，transcript 仍写 admission 时 session_key" do
      dir = gateway_tmp_dir("replay-attrib")
      config = ::Sebas::Platform::Config::Loader.from_content(<<-YAML
        gateway:
          http: { port: 0 }
          ipc: { port: 0 }
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
          alt: { model: fake/chat }
        bindings:
          - { channel: email, account: test-acc, peer: "alice@example.com", agent: main }
          - { channel: email, account: test-acc, peer: "*", agent: alt }
        YAML
      )
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        ::Sebas::Providers::FakeProvider.new("fake/chat", ["ok"])
      end
      # 精确模拟「intent 落库 + admission 后、批次派发执行前」崩溃：
      # 手动 admission（不经 bus 消费，无 transcript/turn 残留）
      message = ::Sebas::Platform::Bus::InboundMessage.new(
        "evt-176", "email", "test-acc", "alice@example.com", "hello"
      )
      snapshot = ::Sebas::Sessions::Scheduling::Policy.resolve_session(nil, nil)
      envelope = ::Sebas::Sessions::Scheduling::InputEnvelope.new(
        "evt-176", "agent:main:test-acc:email:alice@example.com", "email",
        "alice@example.com", 0, ::Time.utc.to_rfc3339, nil, message.to_json, snapshot
      )
      gateway.scheduling.admit(envelope)
      gateway.store.record_intent("evt-176", "message", message.to_json) # pending（未 dispatch）
      gateway.store.session_input_session_key("evt-176")
        .should eq("agent:main:test-acc:email:alice@example.com")
      gateway.shutdown

      # binding 变更：重启后（新 Gateway 实例）按当前 binding 会解析到 alt——
      # 但 replay 必须仍归属 admission 时的 main 会话

      # binding 变更：重启后（新 Gateway 实例）按当前 binding 会解析到 alt——
      # 但 replay 必须仍归属 admission 时的 main 会话
      config2 = ::Sebas::Platform::Config::Loader.from_content(<<-YAML
        gateway:
          http: { port: 0 }
          ipc: { port: 0 }
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
          alt: { model: fake/chat }
        bindings:
          - { channel: email, account: test-acc, peer: "*", agent: alt }
        YAML
      )
      smtp = FakeSmtpServer.new
      smtp.serve
      gateway2 = ::Sebas::Platform::CLI::Gateway.new(config2, dir) do |_agent, _key|
        ::Sebas::Providers::FakeProvider.new("fake/chat", ["ok"])
      end
      gateway2.channels.register(::Sebas::Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway2.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))
      gateway2.run
      ok = wait_for(15.seconds) { gateway2.store.intent_status("evt-176") == "done" }
      gateway2.shutdown
      ok.should be_true

      # transcript 全部归属 admission 时 session_key（user/agent 两条同一会话）
      transcripts = gateway2.store.transcripts("agent:main:test-acc:email:alice@example.com")
      transcripts.map(&.role).should eq(["user", "agent"])
      # 重定向后的 alt 会话无 transcript（归属未被 binding 热换改变）
      gateway2.store.transcripts("agent:alt:test-acc:email:alice@example.com").should be_empty
    end
  end
end
