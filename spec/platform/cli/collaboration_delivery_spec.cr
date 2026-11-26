require "spec"
require "file_utils"
require "json"
require "../../../src/platform/cli/gateway"
require "../../../src/platform/config/loader"
require "../../../src/orchestration/collaboration/collaboration"
require "../../../src/sessions/scheduling/registry"
require "../../../src/channels/email/adapter"
require "../../support/gateway_spec_helper"
require "../../support/fake_smtp_server"

# 脚本化 Provider（#186 spec）：按调用序出脚本响应，记录收到的完整 prompt
# （验收「收方下一 turn 的 prompt 中含该消息」直证）；调用无跨会话共享状态，
# Provider 层不加锁。
private class ScriptedProvider < ::Sebas::Providers::Provider
  @record = [] of ::Sebas::Providers::Message
  @calls = 0

  def initialize(model : String, @take : -> String?)
    super(model)
  end

  def complete(messages : Array(::Sebas::Providers::Message)) : ::Sebas::Providers::Completion
    @record.concat(messages)
    @calls += 1
    ::Sebas::Providers::Completion.new(@take.call || "", nil)
  end

  def seen_prompt : String
    @record.map(&.content).join("\n")
  end
end

# 固定响应 take（Proc(String?) 装箱——Proc 型变不变，字面量需显式统一）
private def script_take(response : String) : Proc(String?)
  boxed = response.as(String?)
  -> { boxed }
end

# 首轮发工具调用（fenced JSON 协议，与 ToolCallParser 契约一致）、
# 后续轮收敛的 take：主触发 turn 调一次 message_agent 后即终答
private def tool_then_idle(tool_call : String) : Proc(String?)
  fenced = "```json\n#{tool_call}\n```"
  calls = Atomic(Int32).new(0)
  -> do
    n = calls.add(1) + 1
    n == 1 ? fenced.as(String?) : "idle"
  end
end

def collab_tmp_dir(name : String) : Path
  dir = Path[Dir.tempdir, "sebas-collab-spec", "#{name}-#{Random::Secure.hex(4)}"]
  FileUtils.rm_rf(dir)
  Dir.mkdir_p(dir)
  dir
end

def collab_agents_dir : Path
  dir = Path[Dir.tempdir, "sebas-collab-spec", "agents-#{Random::Secure.hex(4)}"]
  FileUtils.rm_rf(dir)
  Dir.mkdir_p(dir)
  dir
end

def collab_config : ::Sebas::Platform::Config::Config
  ::Sebas::Platform::Config::Loader.from_content(<<-YAML
    channels:
      email:
        accounts:
          - id: test-acc
            platform: 127.0.0.1
            receive: imap-idle
            smtp: { port: 2525, tls: none }
            credentials: { user: u, password: p }
    agents:
      main: { model: fake/main }
      work: { model: fake/work }
    bindings:
      - { channel: email, account: test-acc, peer: "*", agent: main }
    gateway:
      collaboration: { max_hops: 4 }
    YAML
  )
end

module Sebas
  describe "collaboration delivery（#186 方案 B：内部消息入收方 turn 上下文）" do
    it "端到端：A 调 message_agent → B 下一 turn prompt 含消息（署名+delivery）→ expect_reply 回投 A" do
      dir = collab_tmp_dir("e2e")
      config = collab_config
      work_session = Agents.session_key("work", "internal", "collaboration", "main")
      main_inbox_session = Agents.session_key("main", "internal", "collaboration", "work")

      smtp = FakeSmtpServer.new
      smtp.serve
      # ReAct 工具协议：调用必须包 ```json 围栏（tool_call_parser 只认围栏块）
      tool_call = <<-TOOL
        ```json
        {"tool": "message_agent", "args": {"agent": "work", "content": "hello from main", "expect_reply": true}}
        ```
        TOOL
      main_provider = ScriptedProvider.new("fake/main", tool_then_idle(tool_call))
      work_provider = ScriptedProvider.new("fake/work", script_take("ack from work"))

      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        agent.model == "fake/main" ? main_provider : work_provider
      end
      # 预置 agent 模板（messenger 投递前按 AgentRegistry 校验收方存在；
      # get 只查实例内存 hash，须经 gateway 装配的 registry 注册）
      gateway.agent_registry.get_or_create("main")
      gateway.agent_registry.get_or_create("work")
      # 出站适配器指向假 SMTP（主触发 turn 的终答发信走完整效应三明治）
      gateway.channels.register(Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))

      trigger = Platform::Bus::InboundMessage.new("evt-collab-e2e", "email", "test-acc", "peer@x", "trigger")
      gateway.process_message(trigger)

      # 主触发 turn 完整收敛（发信成功 → intent done）
      wait_for { gateway.store.intent_status("evt-collab-e2e") == "done" }.should be_true

      # B 消费：协作会话 transcript 出现署名行（含 delivery 标记）且 turn 终答落库
      wait_for do
        rows = gateway.store.transcripts(work_session)
        rows.any? { |row| row.role == "user" && row.content.includes?("Message from 🤖 main") } &&
          rows.any? { |row| row.role == "agent" && row.content == "ack from work" }
      end.should be_true

      # expect_reply=true：回复回投到 A 的协作会话（署名行落 transcript，turn 消费）
      wait_for do
        gateway.store.transcripts(main_inbox_session).any? do |row|
          row.role == "user" && row.content.includes?("Message from 🤖 work") &&
            row.content.includes?("ack from work")
        end
      end.should be_true

      # 收方 turn prompt 含署名与 delivery 标记（验收直证）
      work_provider.seen_prompt.should contain("Message from 🤖 main")
      work_provider.seen_prompt.should contain("[delivery: dm:")

      # 消费恰好一次：协作会话 user 行唯一（同 delivery_id 重投走 duplicate）
      gateway.store.transcripts(work_session).count { |row| row.role == "user" }.should eq(1)
      gateway.shutdown
      smtp.close
    end

    it "幂等：同 delivery_id 重投得 duplicate，只消费一次" do
      dir = collab_tmp_dir("idem")
      config = collab_config
      work_session = Agents.session_key("work", "internal", "collaboration", "main")
      work_provider = ScriptedProvider.new("fake/work", script_take("ack"))
      main_provider = ScriptedProvider.new("fake/main", script_take("idle"))
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        agent.model == "fake/main" ? main_provider : work_provider
      end

      signed = "Message from 🤖 main: dup\n[delivery: dm:dup-1]"
      delivery = ::Sebas::Orchestration::Collaboration::Delivery.build(
        "dm:dup-1", "main", "work", work_session, signed, 1, false)
      first = gateway.admit_collaboration(delivery)
      second = gateway.admit_collaboration(delivery)
      first.status.should eq("accepted")
      second.status.should eq("duplicate") # 重投不占批（调度层去重）

      wait_for do
        rows = gateway.store.transcripts(work_session)
        rows.any? { |row| row.role == "user" && row.content.includes?("dup") } &&
          rows.any? { |row| row.role == "agent" }
      end.should be_true
      # 只消费一次：user 行唯一 + intent 终态 done
      gateway.store.transcripts(work_session).count { |row| row.role == "user" }.should eq(1)
      gateway.store.intent_status("dm:dup-1").should eq("done")
      gateway.shutdown
    end

    it "重启续跑：admission 持久化后未消费消息不丢（recover_dispatch 接续）；expect_reply=false 静默" do
      dir = collab_tmp_dir("recovery")
      work_session = Agents.session_key("work", "internal", "collaboration", "main")
      main_inbox_session = Agents.session_key("main", "internal", "collaboration", "work")

      # 「崩溃前」：仅持久 admission（生产同路径 Scheduler），未派发即中断
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      registry = ::Sebas::Sessions::Scheduling::Registry.new(store)
      signed = "Message from 🤖 main: survive restart\n[delivery: dm:restart-1]"
      delivery = ::Sebas::Orchestration::Collaboration::Delivery.build(
        "dm:restart-1", "main", "work", work_session, signed, 1, false)
      snapshot = ::Sebas::Sessions::Scheduling::Policy.resolve_session(nil, nil)
      envelope = ::Sebas::Sessions::Scheduling::InputEnvelope.new(
        delivery.delivery_id, delivery.session_key, "collaboration", delivery.from_agent, 0,
        ::Time.utc.to_rfc3339, nil, delivery.payload, snapshot
      )
      registry.admit(envelope).status.should eq("accepted")
      store.close # 进程在此崩溃：批已持久，turn 未执行

      # 「重启」：新 Gateway 在同一数据目录上恢复续跑
      config = collab_config
      work_provider = ScriptedProvider.new("fake/work", script_take("post-restart ack"))
      main_provider = ScriptedProvider.new("fake/main", script_take("idle"))
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        agent.model == "fake/main" ? main_provider : work_provider
      end
      gateway.scheduling.recover_dispatch # run() 内同款 kick（避免绑端口）

      wait_for do
        rows = gateway.store.transcripts(work_session)
        rows.any? { |row| row.role == "user" && row.content.includes?("survive restart") } &&
          rows.any? { |row| row.role == "agent" && row.content == "post-restart ack" }
      end.should be_true
      gateway.store.intent_status("dm:restart-1").should eq("done")
      # expect_reply=false：不回投（发送方协作会话无行）
      gateway.store.transcripts(main_inbox_session).should be_empty
      gateway.shutdown
    end

    it "崩溃续跑：intent 已 dispatched 的协作投递经 replay_unfinished 续跑不丢" do
      dir = collab_tmp_dir("replay")
      config = collab_config
      work_session = Agents.session_key("work", "internal", "collaboration", "main")
      work_provider = ScriptedProvider.new("fake/work", script_take("replayed ack"))
      main_provider = ScriptedProvider.new("fake/main", script_take("idle"))
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        agent.model == "fake/main" ? main_provider : work_provider
      end

      # 崩溃现场：turn 已派发未完成（intent dispatched，transcript 无行）
      signed = "Message from 🤖 main: crash mid-turn\n[delivery: dm:replay-1]"
      delivery = ::Sebas::Orchestration::Collaboration::Delivery.build(
        "dm:replay-1", "main", "work", work_session, signed, 1, false)
      gateway.store.record_intent(delivery.delivery_id, "message", delivery.payload)
      gateway.store.finish_intent(delivery.delivery_id, "dispatched")

      gateway.replay_unfinished

      wait_for do
        rows = gateway.store.transcripts(work_session)
        rows.any? { |row| row.role == "user" && row.content.includes?("crash mid-turn") } &&
          rows.any? { |row| row.role == "agent" && row.content == "replayed ack" }
      end.should be_true
      gateway.store.intent_status("dm:replay-1").should eq("done")
      gateway.shutdown
    end

    it "拒投审计：未知收方静默返回且 admitter 不投递；拒投经 DeliveryRejected 上浮" do
      store = ::Sebas::Platform::Store::Store.new(
        Path[Dir.tempdir, "sebas-collab-spec", "reject-#{Random::Secure.hex(4)}"] / "sebas.db")
      registry = ::Sebas::Agents::AgentRegistry.new(collab_agents_dir)
      registry.get_or_create("alice")
      messenger = ::Sebas::Orchestration::Collaboration::Messenger.new(registry, store)
      admitted = 0
      messenger.deliver = ->(_delivery : ::Sebas::Orchestration::Collaboration::Delivery) {
        admitted += 1
        true
      }

      # 未知收方：registry 校验前置拦截，admitter 不被调用
      message = messenger.send_message("alice", "ghost", "hi")
      message.should be_nil
      admitted.should eq(0)

      # admission 拒投：DeliveryRejected 上浮（发送方无 ack 可重试）
      registry.get_or_create("bob")
      messenger.deliver = ->(_delivery : ::Sebas::Orchestration::Collaboration::Delivery) { false }
      expect_raises(::Sebas::Orchestration::Collaboration::DeliveryRejected) do
        messenger.send_message("alice", "bob", "hi")
      end
      store.close
    end
  end
end
