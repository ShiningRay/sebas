require "spec"
require "http"
require "file_utils"
require "../../src/channels/lark/callback"
require "../../src/platform/config/loader"
require "../../src/platform/store/store"
require "../../src/platform/bus/bus"

def lark_tmp_store
  dir = Path[ENV["TEMP"], "sebas-lark-spec", Random::Secure.hex(4)]
  FileUtils.rm_rf(dir)
  ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
end

def lark_adapter(store)
  account = ::Sebas::Platform::Config::LarkAccount.from_yaml(<<-YAML
    id: feishu-main
    platform: feishu.cn
    receive: webhook
    credentials:
      app_id: cli_a1
      app_secret: s1
      encrypt_key: ek-1
    YAML
  )
  bus = ::Sebas::Platform::Bus::Bus.new(16)
  adapter = ::Sebas::Channels::Lark::LarkCallbackAdapter.new(account, bus, store)
  {adapter, bus}
end

def lark_post(body : String, encrypt_key : String, ts = "1700000000", nonce = "n1") : HTTP::Request
  signature = ::Digest::SHA256.hexdigest(ts + nonce + encrypt_key + body)
  HTTP::Request.new("POST",
    "/cb/lark/feishu-main/event?timestamp=#{ts}&nonce=#{nonce}",
    body: body,
    headers: HTTP::Headers{
      "Content-Type"             => "application/json",
      "X-Lark-Request-Timestamp" => ts,
      "X-Lark-Request-Nonce"     => nonce,
      "X-Lark-Signature"         => signature,
    })
end

def wait_for(seconds : Time::Span = 5.seconds, &condition : -> Bool) : Bool
  deadline = Time.instant + seconds
  until Time.instant > deadline
    return true if condition.call
    sleep 10.milliseconds
  end
  condition.call
end

ENCRYPT_KEY = "ek-1"

module Sebas
  describe "lark callback channel (M1-WP5)" do
    it "answers url_verification challenge (配置挑战)" do
      store = lark_tmp_store
      adapter, _bus = lark_adapter(store)
      body = %({"type": "url_verification", "challenge": "ajls384kdd"})
      result = adapter.handle_callback(lark_post(body, ENCRYPT_KEY))
      result.status.should eq(200)
      JSON.parse(result.body)["challenge"].as_s.should eq("ajls384kdd")
      store.close
    end

    it "publishes inbound events and dedups event_id (超时重推不二投)" do
      store = lark_tmp_store
      adapter, bus = lark_adapter(store)
      body = %({"header": {"event_id": "e-1", "event_type": "im.message.receive_v1"}, "event": {"sender": {"sender_id": {"open_id": "ou_1"}}, "message": {"content": "hello lark"}}})
      result = adapter.handle_callback(lark_post(body, ENCRYPT_KEY))
      result.status.should eq(200)
      event = bus.receive?(2.seconds).should be_a(::Sebas::Platform::Bus::InboundMessage)
      event = event.as(::Sebas::Platform::Bus::InboundMessage)
      event.peer.should eq("ou_1")
      event.content.should eq("hello lark")

      # 同 event_id 重推：200 但不二投
      result2 = adapter.handle_callback(lark_post(body, ENCRYPT_KEY))
      result2.status.should eq(200)
      bus.receive?(300.milliseconds).should be_nil
      store.close
      bus.close
    end

    it "rejects bad X-Lark-Signature with 401 (fail-closed)" do
      store = lark_tmp_store
      adapter, bus = lark_adapter(store)
      body = %({"header": {"event_id": "e-2"}, "event": {}})
      ts = "1700000000"
      nonce = "n1"
      request = HTTP::Request.new("POST",
        "/cb/lark/feishu-main/event?timestamp=#{ts}&nonce=#{nonce}",
        body: body,
        headers: HTTP::Headers{
          "X-Lark-Request-Timestamp" => ts,
          "X-Lark-Request-Nonce"     => nonce,
          "X-Lark-Signature"         => "bad",
        })
      result = adapter.handle_callback(request)
      result.status.should eq(401)
      bus.receive?(200.milliseconds).should be_nil
      store.close
      bus.close
    end

    it "isolates two accounts (两账号事件各自入会话不串扰)" do
      store = lark_tmp_store
      account_a = ::Sebas::Platform::Config::LarkAccount.from_yaml(
        "id: feishu-main\nplatform: feishu.cn\nreceive: webhook\ncredentials: { app_id: a1, app_secret: s1, encrypt_key: ek-a }\n"
      )
      account_b = ::Sebas::Platform::Config::LarkAccount.from_yaml(
        "id: lark-intl\nplatform: larksuite.com\nreceive: webhook\ncredentials: { app_id: a2, app_secret: s2, encrypt_key: ek-b }\n"
      )
      bus = ::Sebas::Platform::Bus::Bus.new(16)
      adapter_a = ::Sebas::Channels::Lark::LarkCallbackAdapter.new(account_a, bus, store)
      adapter_b = ::Sebas::Channels::Lark::LarkCallbackAdapter.new(account_b, bus, store)

      body_a = %({"header": {"event_id": "ea-1"}, "event": {"message": {"content": "from feishu"}}})
      body_b = %({"header": {"event_id": "eb-1"}, "event": {"message": {"content": "from lark"}}})
      adapter_a.handle_callback(lark_post(body_a, "ek-a")).status.should eq(200)
      adapter_b.handle_callback(lark_post(body_b, "ek-b")).status.should eq(200)

      first = bus.receive?(2.seconds).should be_a(::Sebas::Platform::Bus::InboundMessage)
      second = bus.receive?(2.seconds).should be_a(::Sebas::Platform::Bus::InboundMessage)
      first = first.as(::Sebas::Platform::Bus::InboundMessage)
      second = second.as(::Sebas::Platform::Bus::InboundMessage)
      first.content.should eq("from feishu")
      second.content.should eq("from lark")
      first.account_id.should eq("feishu-main")
      second.account_id.should eq("lark-intl")
      store.close
      bus.close
    end

    it "credential fingerprints differ across platforms (base_url 入账号)" do
      store = lark_tmp_store
      account_a = ::Sebas::Platform::Config::LarkAccount.from_yaml(
        "id: x\nplatform: feishu.cn\ncredentials: { app_id: same, app_secret: same }\n"
      )
      account_b = ::Sebas::Platform::Config::LarkAccount.from_yaml(
        "id: x\nplatform: larksuite.com\ncredentials: { app_id: same, app_secret: same }\n"
      )
      bus = ::Sebas::Platform::Bus::Bus.new(4)
      adapter_a = ::Sebas::Channels::Lark::LarkCallbackAdapter.new(account_a, bus, store)
      adapter_b = ::Sebas::Channels::Lark::LarkCallbackAdapter.new(account_b, bus, store)
      adapter_a.credential_fingerprint.should_not eq(adapter_b.credential_fingerprint)
      store.close
      bus.close
    end
  end
end
