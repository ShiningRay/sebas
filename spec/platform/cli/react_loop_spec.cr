require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/providers/fake_provider"
require "../../support/gateway_spec_helper"
require "../../support/fake_smtp_server"

# 脚本化 Provider（M4.3-WP1 ReAct e2e）：按调用次序返回预设响应——
# 第一轮回工具调用 JSON 块，第二轮回终答。
class ScriptedProvider < ::Sebas::Providers::Provider
  @scripts : Array(String)
  @count = 0
  getter seen_messages : Array(Array(::Sebas::Providers::Message))

  def initialize(model : String, scripts : Array(String))
    super(model)
    @scripts = scripts
    @seen_messages = [] of Array(::Sebas::Providers::Message)
  end

  def complete(messages : Array(::Sebas::Providers::Message)) : ::Sebas::Providers::Completion
    @seen_messages << messages
    idx = @count
    @count += 1
    script = @scripts[idx]? || "script exhausted"
    ::Sebas::Providers::Completion.new(script, nil)
  end
end

module Sebas
  describe "ReAct 工具循环（M4.3-WP1）" do
    it "LLM 发起工具调用 → 执行 → 结果回注 → 终答全链（checkpoint 逐轮复用 task phase）" do
      dir = gateway_tmp_dir("react-e2e")
      config = gw_test_config
      smtp = FakeSmtpServer.new
      smtp.serve
      provider = ScriptedProvider.new("fake/scripted", [
        %(checking memory\n```json\n{"tool": "memory.save", "args": {"key": "react-e2e", "body": "react round ran"}}\n```),
        "final answer after tool round",
      ])
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        provider
      end
      gateway.channels.register(::Sebas::Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))

      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-react-1", "email", "test-acc", "alice@example.com", "run the react loop"
      ))
      gateway.run
      ok = wait_for { gateway.store.intent_status("evt-react-1") == "done" }
      gateway.shutdown
      ok.should be_true

      # 工具协议注入：每轮请求首条 system 含工具清单与调用格式
      provider.seen_messages.each do |round_messages|
        round_messages.first.role.should eq("system")
        round_messages.first.content.should contain("memory.save")
        round_messages.first.content.should contain("fenced JSON")
      end

      # 真实成功的工具执行：第二轮收到「成功」的工具结果回注（不是 error）
      second_round = provider.seen_messages[1]
      last_user = second_round.reverse.find(&.role.==("user"))
      last_user = last_user.should be_a(::Sebas::Providers::Message)
      last_user.content.should contain("memory.save")
      last_user.content.should contain("saved memory/react-e2e") # 工具真实执行成功
      last_user.content.should_not contain("error:")

      # 工具结果持久化到 transcript（role=tool，checkpoint 语义载体）
      roles = gateway.store.transcripts("agent:main:test-acc:email:alice@example.com").map(&.role)
      roles.should contain("tool")

      # 终答在最后
      gateway.store.transcripts("agent:main:test-acc:email:alice@example.com").last.content
        .should eq("final answer after tool round")
      # checkpoint 逐轮复用 task phase（循环 2 轮 → phase=2）
      phase = gateway.store.db.query_one?("SELECT phase FROM tasks WHERE id LIKE 'turn:evt-react-1'") do |row_set|
        row_set.read(Int64)
      end
      phase.should eq(2)
    end

    it "无工具调用时行为与现状一致（回归：单次调用即终答）" do
      dir = gateway_tmp_dir("react-plain")
      config = gw_test_config
      smtp = FakeSmtpServer.new
      smtp.serve
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |agent, _|
        ::Sebas::Providers::FakeProvider.new(agent.model, ["plain final answer"])
      end
      gateway.channels.register(::Sebas::Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))

      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-plain-1", "email", "test-acc", "bob@example.com", "no tools please"
      ))
      gateway.run
      ok = wait_for { gateway.store.intent_status("evt-plain-1") == "done" }
      gateway.shutdown
      ok.should be_true
      gateway.store.transcripts("agent:main:test-acc:email:bob@example.com").last.content
        .should eq("plain final answer")
    end
  end
end
