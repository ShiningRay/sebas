require "spec"
require "../../src/routing/binding"
require "../../src/agents/pool"
require "../../src/platform/config/loader"

def rule(channel, account, peer, agent) : ::Sebas::Routing::BindingRule
  ::Sebas::Routing::BindingRule.new(channel, account, peer, agent)
end

module Sebas
  describe "binding routing table (M1-WP1)" do
    it "matches exact peer at highest specificity (design.md §3.2 层级)" do
      bindings = [
        rule("email", "acc-a", "*", "work"),
        rule("email", "acc-a", "boss@x.com", "boss-agent"),
      ]
      Routing::Table.resolve(bindings, "email", "acc-a", "boss@x.com").should eq("boss-agent")
      Routing::Table.resolve(bindings, "email", "acc-a", "other@x.com").should eq("work")
    end

    it "separates same-peer traffic across accounts (同渠道 N 账号互不串扰)" do
      bindings = [
        rule("email", "acc-a", "*", "agent-a"),
        rule("email", "acc-b", "*", "agent-b"),
      ]
      # 两个账号同一 chat_id 各归各会话（§14 M1 验收第 1 条的会话键口径）
      agent_a = Routing::Table.resolve(bindings, "email", "acc-a", "same@peer").should eq("agent-a")
      agent_b = Routing::Table.resolve(bindings, "email", "acc-b", "same@peer").should eq("agent-b")
      key_a = ::Sebas::Agents.session_key(agent_a.to_s, "acc-a", "email", "same@peer")
      key_b = ::Sebas::Agents.session_key(agent_b.to_s, "acc-b", "email", "same@peer")
      key_a.should eq("agent:agent-a:acc-a:email:same@peer")
      key_b.should eq("agent:agent-b:acc-b:email:same@peer")
      key_a.should_not eq(key_b)
    end

    it "falls back from account wildcard to channel level in order" do
      bindings = [
        rule("email", "*", "vip@x.com", "vip-agent"),
        rule("email", "*", "*", "default-agent"),
      ]
      Routing::Table.resolve(bindings, "email", "any-acc", "vip@x.com").should eq("vip-agent")
      Routing::Table.resolve(bindings, "email", "any-acc", "other@x.com").should eq("default-agent")
    end

    it "uses declaration order to break specificity ties" do
      bindings = [
        rule("email", "*", "*", "first"),
        rule("email", "*", "*", "second"),
      ]
      Routing::Table.resolve(bindings, "email", "acc", "peer").should eq("first")
    end

    it "supports cross-channel fallback bindings" do
      bindings = [rule("*", "*", "*", "catch-all")]
      Routing::Table.resolve(bindings, "lark", "acc", "peer").should eq("catch-all")
      Routing::Table.resolve(bindings, "wecom", "acc", "peer").should eq("catch-all")
    end

    it "fails closed on unmatched bindings (fail-closed 丢弃)" do
      bindings = [rule("email", "acc-a", "*", "agent-a")]
      Routing::Table.resolve(bindings, "lark", "acc-a", "peer").should be_nil
      Routing::Table.resolve(bindings, "email", "acc-b", "peer").should be_nil
      Routing::Table.resolve([] of Routing::BindingRule, "email", "acc", "peer").should be_nil
    end

    it "converts config bindings into rules honoring account existence" do
      config = ::Sebas::Platform::Config::Loader.from_content(<<-YAML
        channels:
          email:
            accounts:
              - id: acc-a
                platform: h1
                receive: imap-idle
                credentials: { user: u, password: p }
        agents:
          main: { model: m }
        bindings:
          - { channel: email, account: acc-a, peer: "*", agent: main }
        YAML
      )
      rules = config.bindings.map do |b|
        Routing::BindingRule.new(b.channel, b.account || "*", b.peer || "*", b.agent)
      end
      Routing::Table.resolve(rules, "email", "acc-a", "anyone").should eq("main")
    end
  end
end
