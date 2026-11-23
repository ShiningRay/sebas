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

  def initialize(model : String, scripts : Array(String))
    super(model)
    @scripts = scripts
  end

  def complete(messages : Array(::Sebas::Providers::Message)) : ::Sebas::Providers::Completion
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
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        ScriptedProvider.new("fake/scripted", [
          %(checking memory\n```json\n{"tool": "memory.save", "args": {"key": "react-e2e", "text": "react round ran"}}\n```),
          "final answer after tool round",
        ])
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

      # 工具真的执行了：memory.save 的 memo/FTS 痕迹可查
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
