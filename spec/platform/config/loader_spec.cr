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

        it "validates gateway.collaboration.max_hops and defaults to 4 (#185 WP1)" do
          Loader.from_content(VALID_YAML).gateway.collaboration.max_hops.should eq(4)

          yaml = VALID_YAML.sub("gateway:\n", "gateway:\n  collaboration: { max_hops: 0 }\n")
          errors = begin
            Loader.from_content(yaml)
            [] of String
          rescue ex : ValidationError
            ex.errors
          end
          errors.join("\n").should contain("gateway.collaboration.max_hops must be >= 1")
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

        describe "provider 层（#214）" do
          it "解析 providers 映射与 agents.<name>.provider 引用" do
            yaml = <<-YAML
              providers:
                deepseek:
                  api_key: sk-shared
                  base_url: https://api.deepseek.com
                  protocol: openai-compatible
                anthropic-p:
                  base_url: https://api.anthropic.com/v1
                  protocol: anthropic
              agents:
                main:
                  provider: deepseek
                  model: deepseek-chat
                work:
                  provider: anthropic-p
                  model: claude-sonnet-4
              YAML
            config = Loader.from_content(yaml)
            config.providers["deepseek"].api_key.should eq("sk-shared")
            config.providers["deepseek"].base_url.should eq("https://api.deepseek.com")
            config.providers["deepseek"].protocol.should eq("openai-compatible")
            config.providers["anthropic-p"].protocol.should eq("anthropic")
            config.agents["main"].provider.should eq("deepseek")
            config.agents["main"].model.should eq("deepseek-chat")
            Loader.validate(config).should be_empty
            Loader.migration_hints(config).should be_empty
          end

          it "base_url 缺省时须规格表可解析：已知厂商回退合法，未知厂商 fail-closed（CodeRabbit：防 reload 半应用态）" do
            # 已知厂商缺省 base_url：规格表兜底，合法
            config = Loader.from_content(<<-YAML
              providers:
                deepseek:
                  api_key: k
              agents:
                main: { provider: deepseek, model: deepseek-chat }
              YAML
            )
            Loader.validate(config).should be_empty

            # 未知厂商缺省 base_url：装配期必然抛 ProviderResolveError，校验期拒绝
            bad = <<-YAML
              providers:
                custom-relay:
                  api_key: k
              agents:
                main: { provider: custom-relay, model: m1 }
              YAML
            expect_raises(ValidationError, /base_url missing and 'custom-relay' is not a known vendor/) do
              Loader.from_content(bad)
            end
          end

          it "protocol 默认 openai-compatible，非法值 fail-closed" do
            config = Loader.from_content(<<-YAML
              providers:
                p1:
                  api_key: k
                  base_url: https://api.example.com
              agents:
                main: { provider: p1, model: m1 }
              YAML
            )
            config.providers["p1"].protocol.should eq("openai-compatible")

            bad = <<-YAML
              providers:
                p1:
                  api_key: k
                  base_url: https://api.example.com
                  protocol: pigeon
              agents:
                main: { provider: p1, model: m1 }
              YAML
            expect_raises(ValidationError, /protocol must be openai-compatible or anthropic/) do
              Loader.from_content(bad)
            end
          end

          it "agent.provider 悬空引用与 provider/provider_ref 冲突 fail-closed" do
            dangling = <<-YAML
              providers: {}
              agents:
                main: { provider: ghost, model: m }
              YAML
            errors = begin
              Loader.from_content(dangling)
              [] of String
            rescue ex : ValidationError
              ex.errors
            end
            errors.join("\n").should contain("agents.main.provider 'ghost' references an undefined providers entry")

            conflict = <<-YAML
              providers:
                p1:
                  base_url: https://a.example.com
                p2:
                  base_url: https://b.example.com
              agents:
                main: { provider: p1, provider_ref: p2, model: m }
              YAML
            expect_raises(ValidationError, /provider \('p1'\) and provider_ref \('p2'\) disagree/) do
              Loader.from_content(conflict)
            end
          end

          it "旧配置给出可读迁移指引且不拒绝加载（过渡支持）" do
            legacy = Loader.from_content(VALID_YAML) # model: deepseek/chat + api_key
            legacy.agents["main"].model.should eq("deepseek/chat")

            hints = Loader.migration_hints(legacy)
            joined = hints.join("\n")
            joined.should contain("agents.main.model 'deepseek/chat' encodes the vendor as a prefix (legacy)")
            joined.should contain("providers.deepseek")
            joined.should contain("agents.main.api_key is deprecated: move it to providers.<name>.api_key")

            # provider_ref 旧写法单独指引
            ref_hints = Loader.migration_hints(Loader.from_content("agents:\n  main: { model: deepseek/chat, provider_ref: deepseek }\n"))
            ref_hints.join("\n").should contain("agents.main.provider_ref is deprecated")

            # 新形状：无指引
            Loader.migration_hints(Loader.from_content(<<-YAML
              providers:
                deepseek:
                  api_key: k
                  base_url: https://api.deepseek.com
              agents:
                main: { provider: deepseek, model: deepseek-chat }
              YAML
            )).should be_empty
          end
        end
      end
    end
  end
end
