require "spec"
require "file_utils"
require "../../src/admin/ipc/server"
require "../../src/admin/tui/client"
require "../../src/platform/store/store"

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
  end
end
