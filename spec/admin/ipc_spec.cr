require "spec"
require "file_utils"
require "../../src/admin/ipc/server"
require "../../src/admin/tui/client"
require "../../src/platform/store/store"
require "../../src/platform/config/schema"
require "../../src/sessions/scheduling/steer"
require "../../src/sessions/lifecycle/lifecycle"
require "../../src/agents/agents"
require "../../src/orchestration/approvals/approvals"

def wait_for(seconds : Time::Span = 5.seconds, &condition : -> Bool) : Bool
  deadline = Time.instant + seconds
  until Time.instant > deadline
    return true if condition.call
    sleep 10.milliseconds
  end
  condition.call
end

def ipc_store : ::Sebas::Platform::Store::Store
  dir = Path[Dir.tempdir, "sebas-ipc-spec", Random::Secure.hex(4)]
  ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
end

module Sebas
  describe "NDJSON IPC + TUI client (M0-WP7)" do
    it "handshakes, serves sessions.read and health via discovery" do
      store = ipc_store
      store.append_transcript("agent:main:acc1:email:p1", "user", "hello there")
      data_dir = Path[Dir.tempdir, "sebas-ipc-spec", Random::Secure.hex(4)]
      server = Admin::IPC::Server.new(store, data_dir, port: 0) { {} of String => JSON::Any }
      server.listen
      begin
        client = Admin::TUI::Client.new(server.discovery_path)
        ack = client.handshake.should_not be_nil
        ack["caps"].as_a.size.should be > 0
        client.protocol_ok?.should be_true

        health = client.request("system.health").should_not be_nil
        health["ok"].as_bool.should be_true

        sessions = client.request("sessions.list").should_not be_nil
        sessions["payload"]["sessions"].as_a.size.should eq(1)

        read = client.request("sessions.read", {"session_key" => JSON::Any.new("agent:main:acc1:email:p1")}).should_not be_nil
        entries = read["payload"]["entries"].as_a
        entries.size.should eq(1)
        JSON.parse(entries[0].as_s)["content"].as_s.should eq("hello there")

        # 未握手客户端被拒绝
        raw = TCPSocket.new("127.0.0.1", server.port)
        raw.sync = true
        raw.read_timeout = 3.seconds
        raw.puts("garbage")
        reply = raw.gets.should_not be_nil
        JSON.parse(reply)["error"].as_s.should contain("handshake")
        raw.close
        client.close
      ensure
        server.close
        store.close
      end
    end

    it "rejects oversized frames (8MiB 上限)" do
      store = ipc_store
      data_dir = Path[Dir.tempdir, "sebas-ipc-spec", Random::Secure.hex(4)]
      server = Admin::IPC::Server.new(store, data_dir, port: 0) { {} of String => JSON::Any }
      server.listen
      begin
        raw = TCPSocket.new("127.0.0.1", server.port)
        raw.sync = true
        raw.read_timeout = 3.seconds
        big = "x" * (Admin::IPC::MAX_FRAME + 1024)
        begin
          raw.puts(big) # 超限帧：服务端判坏帧并断开
          raw.flush
        rescue IO::Error
          nil # 服务端可能先关闭连接
        end
        # 服务端可先回握手错误再关闭；最终连接终止（8MiB 防线，不炸进程）
        first = raw.gets
        if first
          err = JSON.parse(first)["error"]?.try(&.as_s?) || ""
          err.should contain("handshake")
          raw.gets.should be_nil
        end
        raw.close
      ensure
        server.close
        store.close
      end
    end

    it "fans bus events out to subscribed TUI clients (会话流实时观察)" do
      store = ipc_store
      data_dir = Path[Dir.tempdir, "sebas-ipc-spec", Random::Secure.hex(4)]
      server = Admin::IPC::Server.new(store, data_dir, port: 0) { {} of String => JSON::Any }
      server.listen
      begin
        client = Admin::TUI::Client.new(server.discovery_path)
        client.handshake
        client.request("events.subscribe")
        wait_for { server.tap.subscriber_count == 1 }.should be_true

        server.tap.publish(Admin::IPC.event_line("inbound.message", {
          "session_key" => JSON::Any.new("agent:main:acc1:email:p1"),
          "content"     => JSON::Any.new("live stream"),
        }))
        got = client.read_response(3.seconds) { |frame_data| frame_data["type"]?.try(&.as_s?) == "event.inbound.message" }
        content = got.try(&.["payload"]["content"].as_s?)
        content.should eq("live stream")
        client.close
      ensure
        server.close
        store.close
      end
    end

    it "lifecycle/templates 命令面（M4.4-WP4）：dormant 执行 + 负数拒绝 + 未装配报错" do
      store = ipc_store
      data_dir = Path[Dir.tempdir, "sebas-ipc-spec", Random::Secure.hex(4)]
      server = Admin::IPC::Server.new(store, data_dir, port: 0) { {} of String => JSON::Any }
      server.listen
      begin
        client = Admin::TUI::Client.new(server.discovery_path) # discovery 同源 token → 认证
        client.handshake

        # 未装配 → 可读错误
        missing = client.request("sessions.dormant").should_not be_nil
        missing["error"].as_s.should contain("lifecycle 组件未装配")

        lifecycle = ::Sebas::Sessions::Lifecycle::Store.new(store, data_dir) # 与 gateway 装配同参
        server.lifecycle_store = lifecycle
        lifecycle.touch("agent:main:acc:email:ipc4@example.com", "main", "user")

        dormant = client.request("sessions.dormant").should_not be_nil
        dormant["payload"]["dormant"].as_a.should be_empty # 默认阈值下刚 touch 不休眠

        # older_than_days=0：真实休眠转换覆盖（防过滤条件写反仍通过）
        zero = client.request("sessions.dormant", {"older_than_days" => JSON::Any.new(0_i64)}).should_not be_nil
        zero["payload"]["dormant"].as_a.should eq(["agent:main:acc:email:ipc4@example.com"])

        rejected = client.request("sessions.dormant", {"older_than_days" => JSON::Any.new(-1_i64)}).should_not be_nil
        rejected["error"].as_s.should contain("non-negative")

        client.close
      ensure
        server.close
        store.close
      end
    end

    it "sessions.steer（M4.5-WP4）：未装配报错 + handler 回执（写认证）" do
      store = ipc_store
      data_dir = Path[Dir.tempdir, "sebas-ipc-spec", Random::Secure.hex(4)]
      server = Admin::IPC::Server.new(store, data_dir, port: 0) { {} of String => JSON::Any }
      server.listen
      begin
        client = Admin::TUI::Client.new(server.discovery_path)
        client.handshake

        missing = client.request("sessions.steer", {
          "session_key" => JSON::Any.new("agent:main:acc:email:st@example.com"),
          "payload"     => JSON::Any.new("纠偏"),
        }).should_not be_nil
        missing["error"].as_s.should contain("steer 中心未装配")

        registry = ::Sebas::Sessions::Scheduling::TurnRegistry.new
        center = ::Sebas::Sessions::Scheduling::SteerCenter.new(store, registry,
          -> { ::Sebas::Sessions::Scheduling::PolicySnapshot.new(
            "queue", 0_i64, 5000_i64, 20_i64, 65536_i64, true, "session", 8_i64, 32_i64, 1_048_576_i64,
            true, 300_i64, 16_i64, 30_000_i64) })
        server.steer_handler = ->(session_key : String, payload : String, turn_id : String?, generation : Int64?) do
          center.submit(session_key, payload, target_turn_id: turn_id, target_generation: generation)
        end
        receipt = client.request("sessions.steer", {
          "session_key" => JSON::Any.new("agent:main:acc:email:st@example.com"),
          "payload"     => JSON::Any.new("改用中文"),
        }).should_not be_nil
        receipt["payload"]["status"].as_s.should eq("queued") # 无活跃 turn
        receipt["payload"]["reason"].as_s.should eq("no_active_turn")
        client.close
      ensure
        server.close
        store.close
      end
    end

    it "templates 命令面（M4.4-WP4）：clone 成功与冲突报错" do
      store = ipc_store
      data_dir = Path[Dir.tempdir, "sebas-ipc-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(data_dir / "agents")
      server = Admin::IPC::Server.new(store, data_dir, port: 0) { {} of String => JSON::Any }
      server.listen
      begin
        registry = ::Sebas::Agents::AgentRegistry.new(data_dir / "agents")
        registry.get_or_create("ipc-tpl")
        server.template_registry = registry

        client = Admin::TUI::Client.new(server.discovery_path)
        client.handshake
        cloned = client.request("templates.clone", {
          "template" => JSON::Any.new("ipc-tpl"),
          "new_id"   => JSON::Any.new("ipc-clone"),
        }).should_not be_nil
        cloned["payload"]["id"].as_s.should eq("ipc-clone")

        conflict = client.request("templates.clone", {
          "template" => JSON::Any.new("ipc-tpl"),
          "new_id"   => JSON::Any.new("ipc-clone"),
        }).should_not be_nil
        conflict["error"].as_s.should contain("already exists")
        client.close
      ensure
        server.close
        store.close
      end
    end
  end
end
