require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/providers/fake_provider"
require "../../support/gateway_spec_helper"
require "../../support/fake_smtp_server"

# 脚本化共享 Provider：跨实例共享脚本次序（对话轮/分身轮按序推进）
class SharedScriptedProvider < ::Sebas::Providers::Provider
  @@scripts = [] of String
  @@count = 0

  def self.scripts=(scripts : Array(String))
    @@scripts = scripts
    @@count = 0
  end

  def initialize(model : String = "fake/scripted")
    super(model)
  end

  def complete(messages : Array(::Sebas::Providers::Message)) : ::Sebas::Providers::Completion
    idx = @@count
    @@count += 1
    script = @@scripts[idx]? || "script exhausted"
    ::Sebas::Providers::Completion.new(script, nil)
  end
end

module Sebas
  describe "对话流内自然 fork（M4.3-WP2，semantics §6）" do
    it "对话内 fork → 审批通过 → join 回写父会话（fork 一等公民全链）" do
      dir = gateway_tmp_dir("fork-dialog")
      SharedScriptedProvider.scripts = [
        %(researching... ```json\n{"tool": "fork", "args": {"task": "explore options", "count": 2, "mode": "allSettled"}}\n```),
        "subagent result A",
        "subagent result B",
        "final answer after join",
      ]
      config = gw_test_config
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        SharedScriptedProvider.new(agent.model)
      end
      smtp = FakeSmtpServer.new
      smtp.serve
      gateway.channels.register(::Sebas::Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))

      # 人工审批：fork L3 pending 出现即批准（对话=人工在场）
      spawn do
        wait_for(20.seconds) { gateway.approvals.pending_requests.size > 0 }
        gateway.approvals.pending_requests.each { |req| gateway.approvals.approve(req.id, "operator") }
      end

      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-fork-dialog-1", "email", "test-acc", "alice@example.com", "并行查方案"
      ))
      gateway.run
      ok = wait_for(30.seconds) { gateway.store.intent_status("evt-fork-dialog-1") == "done" }
      gateway.shutdown
      ok.should be_true

      parent_session = "agent:main:test-acc:email:alice@example.com"
      contents = gateway.store.transcripts(parent_session).map(&.content)
      # join.report 回写父会话（fork → join 对话内自然可见）
      report_line = contents.find(&.starts_with?("{"))
      report = JSON.parse(report_line.as(String))
      report["type"].as_s.should eq("join.report")
      report["fork_id"].as_s.should start_with("fork:")
      report["members"].as_a.size.should eq(2)
      # 分身任务落库
      gateway.store.db.query_one?("SELECT COUNT(*) FROM tasks WHERE kind = 'fork_child'", as: Int64)
        .should eq(2)
      # 终答在 join 之后
      contents.last.should eq("final answer after join")
    end

    it "审批拦截：fork L3 未批不执行（deny 回执进对话）" do
      dir = gateway_tmp_dir("fork-dialog-denied")
      SharedScriptedProvider.scripts = [
        %(trying to fork\n```json\n{"tool": "fork", "args": {"task": "unapproved task"}}\n```),
        "could not fork; reported to user",
      ]
      config = gw_test_config
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        SharedScriptedProvider.new(agent.model)
      end
      smtp = FakeSmtpServer.new
      smtp.serve
      gateway.channels.register(::Sebas::Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))

      # 人工拒绝：fork L3 pending 出现即 deny（审批拦截实测）
      spawn do
        wait_for(20.seconds) { gateway.approvals.pending_requests.size > 0 }
        gateway.approvals.pending_requests.each { |req| gateway.approvals.deny(req.id, "operator") }
      end

      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-fork-dialog-2", "email", "test-acc", "bob@example.com", "fork without approval"
      ))
      gateway.run
      ok = wait_for(30.seconds) { gateway.store.intent_status("evt-fork-dialog-2") == "done" }
      gateway.shutdown
      ok.should be_true

      parent_session = "agent:main:test-acc:email:bob@example.com"
      contents = gateway.store.transcripts(parent_session).map(&.content)
      # fork 未产生任何分身任务（拦截）
      gateway.store.db.query_one?("SELECT COUNT(*) FROM tasks WHERE kind = 'fork_child'", as: Int64)
        .should eq(0)
      # tool 行记录审批拒绝
      tool_line = contents.find(&.starts_with?("fork:"))
      tool_line = tool_line.as(String)
      tool_line.should contain("denied by operator")
      contents.last.should eq("could not fork; reported to user")
    end
  end
end
