require "spec"
require "../../../src/platform/config/loader"

module Sebas
  module Platform
    module Config
      VALID_YAML = <<-YAML
        channels:
          email:
            accounts:
              - id: personal-mailbox
                platform: imap.example.com
                receive: imap-idle
                smtp: { port: 465, tls: implicit }
                credentials:
                  user: someone@example.com
                  password: secret
        agents:
          main:
            model: deepseek/chat
            api_key: sk-test
            memory: { window: 50 }
            tools: { allow: ["*"] }
        bindings:
          - { channel: email, account: personal-mailbox, peer: "*", agent: main }
        gateway:
          http: { bind: 127.0.0.1, port: 18790, auth: token }
          ipc: { mode: auto, port: 18791 }
          data_dir: data
        YAML

      describe Loader do
        it "parses a valid config into typed objects" do
          config = Loader.from_content(VALID_YAML)
          account = config.channels.email.try(&.accounts.first?)
          account.try(&.id).should eq("personal-mailbox")
          account.try(&.platform).should eq("imap.example.com")
          account.try(&.receive).should eq("imap-idle")
          account.try(&.smtp).try(&.port).should eq(465)
          account.try(&.credentials["password"]).should eq("secret")
          config.agents["main"].model.should eq("deepseek/chat")
          config.agents["main"].memory.try(&.window).should eq(50)
          config.bindings.first.agent.should eq("main")
          config.gateway.http.try(&.port).should eq(18790)
        end

        it "reports line numbers for broken YAML" do
          broken = "channels:\n  email:\n   accounts: [oops\n"
          expect_raises(ConfigError, /line \d+/) do
            Loader.from_content(broken)
          end
        end

        it "collects readable validation errors" do
          yaml = <<-YAML
            channels:
              email:
                accounts:
                  - id: ""
                    receive: imap-idle
                  - id: broken
                    platform: imap.example.com
                    receive: pigeon
            agents: {}
            bindings:
              - { channel: pigeon, account: "nope", agent: ghost }
              - { channel: email, account: ghost-mailbox, agent: main }
            gateway:
              http: { port: 99999, auth: open }
            YAML
          errors = begin
            Loader.from_content(yaml)
            [] of String
          rescue ex : ValidationError
            ex.errors
          end
          joined = errors.join("\n")
          joined.should contain("at least one agent must be defined")
          joined.should contain("channels.email.accounts[0].id must not be empty")
          joined.should contain("accounts[0].platform (IMAP host) is required")
          joined.should contain("accounts[0].credentials.user is required")
          joined.should contain("accounts[1].receive must be imap-idle or gmail-api")
          joined.should contain("channel 'pigeon' is not a known channel")
          joined.should contain("agent 'ghost' references an undefined agent")
          joined.should contain("account 'ghost-mailbox' does not exist")
          joined.should contain("gateway.http.port must be 1..65535")
          joined.should contain("gateway.http.auth must be token, password or tailscale")
        end

        it "detects duplicate account ids within a channel" do
          yaml = <<-YAML
            channels:
              email:
                accounts:
                  - id: dup
                    platform: imap.example.com
                    receive: imap-idle
                    credentials: { user: u, password: p }
                  - id: dup
                    platform: imap.example.com
                    receive: imap-idle
                    credentials: { user: u, password: p }
            agents:
              main: { model: deepseek/chat }
            YAML
          expect_raises(ValidationError, /duplicates an earlier account id/) do
            Loader.from_content(yaml)
          end
        end

        it "expands ${VAR} environment references" do
          ENV["SEBAS_SPEC_TOKEN"] = "tok-123"
          config = Loader.from_content("agents:\n  main:\n    model: m\n    api_key: ${SEBAS_SPEC_TOKEN}\n")
          config.agents["main"].api_key.should eq("tok-123")
          ENV.delete("SEBAS_SPEC_TOKEN")
        end

        it "keeps missing env references verbatim and fails readable" do
          yaml = "agents:\n  main:\n    model: m\nbindings:\n  - { channel: email, agent: main }\n"
          config = Loader.from_content(yaml)
          config.channels.email.should be_nil
          config.bindings.first.account.should be_nil
        end

        it "accepts wecom and lark accounts through the macro-generated wrappers" do
          yaml = <<-YAML
            channels:
              wecom:
                accounts:
                  - id: company-a
                    mode: aibot-longconn
                    credentials: { corpid: c1, aibot_secret: s1 }
              lark:
                accounts:
                  - id: feishu-main
                    platform: feishu.cn
                    receive: ws-longconn
                    credentials: { app_id: a1, app_secret: s2 }
            agents:
              main: { model: deepseek/chat }
            YAML
          config = Loader.from_content(yaml)
          config.channels.wecom.try(&.accounts.first.mode).should eq("aibot-longconn")
          config.channels.lark.try(&.accounts.first.platform).should eq("feishu.cn")
          Loader.validate(config).should be_empty
        end

        it "loads from a file and rejects a missing path" do
          path = Path[Dir.tempdir, "sebas-spec-config.yaml"]
          File.write(path, VALID_YAML)
          config = Loader.load(path)
          config.agents.size.should eq(1)
          File.delete(path)
          expect_raises(ConfigError, /not found/) do
            Loader.load(path)
          end
        end
      end
    end
  end
end
