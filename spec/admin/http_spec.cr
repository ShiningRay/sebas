require "spec"
require "file_utils"
require "http/client"
require "../../src/admin/http/server"
require "../../src/channels/base"
require "../../src/channels/registry"
require "../../src/platform/bus/bus"
require "../../src/admin/ipc/server"
require "../../src/platform/store/store"
require "../../src/sessions/lifecycle/lifecycle"
require "../../src/agents/agents"

# 回调测试适配器：验签口令头不匹配 → 401（fail-closed）
class CallbackAdapter < ::Sebas::Channels::ChannelAdapter
  getter started = Channel(Nil).new(1)
  property secret : String = "s3cret"

  def initialize(account_id : String)
    super("email", account_id)
  end

  def start : Nil
    started.send(nil)
  end

  def stop : Nil; end

  def send(peer : String, content : String, idempotency_key : String? = nil) : ::Sebas::Channels::SendResult
    ::Sebas::Channels::SendResult.success
  end

  def handle_callback(request : HTTP::Request) : ::Sebas::Channels::CallbackResult
    return ::Sebas::Channels::CallbackResult.json(401, %({"error": "bad signature"})) unless request.headers["X-Signature"]? == @secret
    ::Sebas::Channels::CallbackResult.json(200, %({"received": true}))
  end
end

def http_wait_for(seconds : Time::Span = 5.seconds, &condition : -> Bool) : Bool
  deadline = Time.instant + seconds
  until Time.instant > deadline
    return true if condition.call
    sleep 20.milliseconds
  end
  condition.call
end

def bus_tap(bus) : ::Sebas::Admin::IPC::EventTap
  tap = ::Sebas::Admin::IPC::EventTap.new
  spawn do
    loop do
      event = bus.receive?
      break if event.nil?
      case event
      when ::Sebas::Platform::Bus::AccountEvent
        tap.publish(::Sebas::Admin::IPC.event_line("account.#{event.kind}", {
          "account_id" => JSON::Any.new(event.account_id),
        }))
      end
    end
  rescue ::Exception
    nil
  end
  tap
end

def started_server(token : String? = "tok-1")
  bus = ::Sebas::Platform::Bus::Bus.new(32)
  channels = ::Sebas::Channels::Registry.new
  server = ::Sebas::Admin::HTTP::Server.new(channels, bus_tap(bus), "127.0.0.1", 0, "token", token) do
    {"accepted" => JSON::Any.new(true)} of String => JSON::Any
  end
  server.listen
  {server, channels, bus}
end

module Sebas
  describe "HTTP admin server (M1-WP9)" do
    it "rejects requests without a bearer token with 401 (未带 token 401)" do
      server, channels, bus = started_server("tok-1")
      channels.register(CallbackAdapter.new("acc-1"))
      begin
        response = HTTP::Client.get("http://127.0.0.1:#{server.port}/api/v1/system.health")
        response.status_code.should eq(401)
      ensure
        server.close
        bus.close
      end
    end

    it "serves health/accounts/reload with a valid token" do
      server, channels, bus = started_server("tok-1")
      channels.register(CallbackAdapter.new("acc-1"))
      begin
        headers = HTTP::Headers{"Authorization" => "Bearer tok-1"}
        health = HTTP::Client.get("http://127.0.0.1:#{server.port}/api/v1/system.health", headers: headers)
        health.status_code.should eq(200)
        JSON.parse(health.body)["status"].as_s.should eq("ok")

        accounts = HTTP::Client.get("http://127.0.0.1:#{server.port}/api/v1/accounts.list", headers: headers)
        JSON.parse(accounts.body)["accounts"].as_a.size.should eq(1)

        reload = HTTP::Client.post("http://127.0.0.1:#{server.port}/api/v1/config.reload", headers: headers)
        JSON.parse(reload.body)["accepted"].as_bool.should be_true

        wrong = HTTP::Client.get("http://127.0.0.1:#{server.port}/api/v1/system.health",
          headers: HTTP::Headers{"Authorization" => "Bearer nope"})
        wrong.status_code.should eq(401)
      ensure
        server.close
        bus.close
      end
    end

    it "serves callbacks and API on the same port; 404 without adapter (同端口共存)" do
      server, channels, bus = started_server(nil) # 回调面在 token 模式下仍必须可用
      adapter = CallbackAdapter.new("acc-1")
      channels.register(adapter)
      begin
        # 回调不受 bearer 门控（各平台验签自担）
        good = HTTP::Client.post("http://127.0.0.1:#{server.port}/cb/email/acc-1/msg",
          headers: HTTP::Headers{"X-Signature" => "s3cret"}, body: "payload")
        good.status_code.should eq(200)
        JSON.parse(good.body)["received"].as_bool.should be_true

        bad_sig = HTTP::Client.post("http://127.0.0.1:#{server.port}/cb/email/acc-1/msg",
          headers: HTTP::Headers{"X-Signature" => "wrong"}, body: "x")
        bad_sig.status_code.should eq(401) # 验签失败 fail-closed

        missing = HTTP::Client.post("http://127.0.0.1:#{server.port}/cb/email/ghost/msg", body: "x")
        missing.status_code.should eq(404) # 无对应 adapter
      ensure
        server.close
        bus.close
      end
    end

    it "streams SSE events to subscribed clients" do
      server, _channels, bus = started_server("tok-1")
      begin
        # 原始 socket 读 SSE（HTTP::Client body_io 无读超时，避免挂起）
        sock = TCPSocket.new("127.0.0.1", server.port)
        sock.read_timeout = 5.seconds
        sock.sync = true
        sock.puts("GET /api/v1/events HTTP/1.1")
        sock.puts("Host: 127.0.0.1")
        sock.puts("Authorization: Bearer tok-1")
        sock.puts("Accept: text/event-stream")
        sock.puts("Connection: close")
        sock.puts("")

        header = sock.gets.should_not be_nil
        header.to_s.should contain("200")
        connected = false
        16.times do # 跳过响应头直到心跳帧
          line = sock.gets.to_s
          connected = true if line.includes?(": connected")
          break if connected
        end
        connected.should be_true # 订阅建立（心跳首帧）

        bus.publish(Platform::Bus::AccountEvent.new("evt-sse-1", "email", "acc-1", "health.online"))
        event_line = ""
        10.times do
          line = sock.gets
          line = line.nil? ? "" : line
          next unless line.starts_with?("data: ")
          event_line = line
          break
        end
        event_line.should contain("event.account.health.online")
        sock.close
      ensure
        server.close
        bus.close
      end
    end

    it "sessions lifecycle 与 templates 管理面（M4.4-WP4）：注入后可查可操作，非法体 400" do
      server, _channels, bus = started_server("tok-1")
      begin
        dir = Path[Dir.tempdir, "sebas-http-wp4-spec", Random::Secure.hex(4)]
        FileUtils.mkdir_p(dir / "agents")
        store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
        lifecycle = ::Sebas::Sessions::Lifecycle::Store.new(store, dir)
        registry = ::Sebas::Agents::AgentRegistry.new(dir / "agents")
        registry.get_or_create("tpl-one")
        server.lifecycle = lifecycle
        server.templates = registry
        headers = HTTP::Headers{"Authorization" => "Bearer tok-1"}
        base = "http://127.0.0.1:#{server.port}"

        lifecycle.touch("agent:main:acc:email:wp4@example.com", "main", "user")
        listed = HTTP::Client.get("#{base}/api/v1/sessions.lifecycle?status=active", headers: headers)
        listed.status_code.should eq(200)
        JSON.parse(listed.body)["sessions"].as_a.size.should eq(1)

        archived = HTTP::Client.post(
          "#{base}/api/v1/sessions.archive?session_key=agent:main:acc:email:wp4@example.com", headers: headers)
        JSON.parse(archived.body)["archived"].as_s.should eq("agent:main:acc:email:wp4@example.com")

        gc = HTTP::Client.post("#{base}/api/v1/sessions.gc", headers: headers)
        JSON.parse(gc.body)["collected"].as_i.should eq(0) # confirm 闸缺省不放行

        list = HTTP::Client.get("#{base}/api/v1/templates.list", headers: headers)
        JSON.parse(list.body)["templates"].as_a.should contain("tpl-one")

        bad_json = HTTP::Client.post("#{base}/api/v1/templates.clone", headers: headers, body: "[1,2]")
        bad_json.status_code.should eq(400) # 根非对象 → 400 不再 500

        missing = HTTP::Client.post("#{base}/api/v1/templates.clone", headers: headers, body: "{}")
        missing.status_code.should eq(400)

        cloned = HTTP::Client.post("#{base}/api/v1/templates.clone", headers: headers,
          body: %({"template": "tpl-one", "new_id": "tpl-clone"}))
        JSON.parse(cloned.body)["id"].as_s.should eq("tpl-clone")
        store.close
      ensure
        server.close
        bus.close
      end
    end
  end
end
