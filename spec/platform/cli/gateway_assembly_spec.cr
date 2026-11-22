require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/platform/config/loader"
require "../../support/gateway_spec_helper"
require "../../support/fake_smtp_server"

module Sebas
  describe "gateway orchestration assembly (M4.1-WP1, Q4 全线前置首包)" do
    it "exposes AgentRegistry / Approvals::Center / ForkManager / JoinWriter in-process (装配存在性)" do
      dir = gateway_tmp_dir("assembly")
      gateway = Platform::CLI::Gateway.new(gw_test_config, dir) do |agent, _key|
        Providers::FakeProvider.new(agent.model, ["ok"])
      end
      gateway.shutdown

      gateway.agent_registry.should be_a(Agents::AgentRegistry)
      gateway.approvals.should be_a(Orchestration::Approvals::Center)
      gateway.fork_manager.should be_a(Orchestration::Fork::ForkManager)
      gateway.join_writer.should be_a(Orchestration::Fork::JoinWriter)
      # 组件共享同一生产依赖实例（单一事实源：store/providers 不得有第二份）
      gateway.fork_manager.store.should be(gateway.store)
      gateway.fork_manager.approvals.should be(gateway.approvals)
      gateway.join_writer.store.should be(gateway.store)
    end

    it "keeps admission enqueue key and dispatch processing key identical (同 peer 键一致性)" do
      smtp = FakeSmtpServer.new
      smtp.serve
      dir = gateway_tmp_dir("assembly-keys")
      gateway = Platform::CLI::Gateway.new(gw_test_config, dir) do |agent, _key|
        Providers::FakeProvider.new(agent.model, ["ack"])
      end
      gateway.channels.register(Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))
      gateway.bus.publish(Platform::Bus::InboundMessage.new(
        "evt-asm-1", "email", "test-acc", "dave@example.com", "key check"
      ))
      gateway.run
      ok = wait_for { gateway.store.intent_status("evt-asm-1") == "done" }
      gateway.shutdown
      ok.should be_true

      # 键一致性实证（入队与处理同键，无 "main" 硬编码旁路）：
      # ①事件走 admission（入队发生，非 bus 直投）；②turn 产物落在
      # Routing.resolve 后的 routed 会话键下——若入队键≠处理键，
      # 批次无法派发到 pool、turn 无法执行，本断言即失败。
      expected = Agents.session_key("main", "test-acc", "email", "dave@example.com")
      store = Platform::Store::Store.new(dir / "sebas.db")
      store.session_input?("evt-asm-1").should be_true
      transcripts = store.transcripts(expected)
      transcripts.map(&.role).should eq(["user", "agent"])
      transcripts[0].content.should eq("key check")
      store.close
    end
  end

  describe "ForkManager / JoinWriter key contract (semantics §1.3 / §3)" do
    it "derives member keys and task ids from a fork-level fork_id" do
      dir = gateway_tmp_dir("fork-keys")
      fm = Orchestration::Fork::ForkManager.new(
        Platform::Store::Store.new(dir / "sebas.db"),
        Agents::AgentRegistry.new(dir / "agents"),
        Providers::Pool.new,
        Orchestration::Approvals::Center.new
      )

      fork_id = fm.new_fork_id
      fork_id.should match(/\bfork:[0-9a-f]{8}\z/)

      key1 = fm.member_session_key("main", fork_id, 1)
      key2 = fm.member_session_key("main", fork_id, 2)
      # 成员级独立会话：同次 fork 的两个成员键不同，且五段结构同源（Agents.session_key 构造）
      key1.should eq(Agents.session_key("main", "internal", "fork", "#{fork_id}:1"))
      key2.should eq(Agents.session_key("main", "internal", "fork", "#{fork_id}:2"))
      key1.should_not eq(key2)
      fm.member_task_id(fork_id, 1).should eq("#{fork_id}:1")
    end

    it "builds the join memo idempotency key and reflects written state" do
      dir = gateway_tmp_dir("join-writer")
      store = Platform::Store::Store.new(dir / "sebas.db")
      writer = Orchestration::Fork::JoinWriter.new(store)

      writer.memo_key("fork:abc12345").should eq("join:fork:abc12345:written")
      writer.written?("fork:abc12345").should be_false
      store.memo_put("join:fork:abc12345:written", "1")
      writer.written?("fork:abc12345").should be_true
      store.close
    end
  end
end
