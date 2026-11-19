require "spec"
require "http"
require "uri"
require "file_utils"
require "../../src/channels/wecom/crypto"
require "../../src/channels/wecom/app_callback"
require "../../src/platform/store/store"
require "../../src/platform/config/loader"
require "../../src/platform/bus/bus"

TOKEN        = "testtoken"
AES_KEY_43   = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopq" # 43 chars
CORPID       = "corp-aaa"
OTHER_CORPID = "corp-bbb"

def build_crypto : ::Sebas::Channels::Wecom::WecomCrypto
  ::Sebas::Channels::Wecom::WecomCrypto.new(TOKEN, AES_KEY_43, CORPID)
end

def build_adapter(store)
  account = ::Sebas::Platform::Config::WecomAccount.from_yaml(<<-YAML
    id: corp-aaa
    mode: app-callback
    credentials:
      corpid: #{CORPID}
      token: #{TOKEN}
      aes_key: #{AES_KEY_43}
    YAML
  )
  bus = ::Sebas::Platform::Bus::Bus.new(16)
  adapter = ::Sebas::Channels::Wecom::WecomCallbackAdapter.new(account, bus, store)
  {adapter, bus}
end

def post_request(body : String, signature : String, ts = "1700000000", nonce = "n1") : HTTP::Request
  HTTP::Request.new("POST",
    "/cb/wecom/corp-aaa/msg?msg_signature=#{signature}&timestamp=#{ts}&nonce=#{nonce}",
    body: body, headers: HTTP::Headers{"Content-Type" => "application/json"})
end

module Sebas
  describe "wecom callback channel (M1-WP4)" do
    it "encrypts/decrypts round-trip with receiveid intact" do
      crypto = build_crypto
      encrypt = crypto.encrypt("hello wecom", CORPID)
      msg = crypto.decrypt(encrypt, CORPID)
      msg.should eq("hello wecom")
    end

    it "rejects cross-tenant receiveid (§14 M1 验收第 2 条)" do
      crypto = build_crypto
      encrypt = crypto.encrypt("hello", CORPID)
      expect_raises(::Sebas::Channels::Wecom::CryptoError, /receiveid mismatch/) do
        crypto.decrypt(encrypt, OTHER_CORPID)
      end
    end

    it "verifies msg_signature (SHA1 of sorted token/timestamp/nonce/encrypt)" do
      crypto = build_crypto
      encrypt = crypto.encrypt("x", CORPID)
      sig = crypto.signature("1700000000", "n1", encrypt)
      crypto.verify_signature(sig, "1700000000", "n1", encrypt).should be_true
      crypto.verify_signature("bad", "1700000000", "n1", encrypt).should be_false
    end

    it "handles GET URL verification (echo within 1s 口径)" do
      dir = Path[ENV["TEMP"], "sebas-wecom-spec", Random::Secure.hex(4)]
      FileUtils.rm_rf(dir)
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      adapter, _bus = build_adapter(store)
      crypto = build_crypto
      echostr = crypto.encrypt("echo-msg-123", CORPID)
      sig = crypto.signature("1700000000", "n1", echostr)

      # 真实企微 GET 会对参数做 URL 编码（Base64 的 +/= 必须转义，否则 query 解码破坏密文）
      result = adapter.handle_callback(HTTP::Request.new("GET",
        "/cb/wecom/corp-aaa?msg_signature=#{URI.encode_www_form(sig)}&timestamp=1700000000&nonce=n1&echostr=#{URI.encode_www_form(echostr)}"))
      result.status.should eq(200)
      result.body.should eq("echo-msg-123")
      store.close
      FileUtils.rm_rf(dir)
    end

    it "publishes inbound messages and deduplicates msgid (§5.5 排重)" do
      dir = Path[ENV["TEMP"], "sebas-wecom-spec", Random::Secure.hex(4)]
      FileUtils.rm_rf(dir)
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      adapter, bus = build_adapter(store)
      crypto = build_crypto

      xml = %(<xml><msgid>12345</msgid><from>userid:zhang</from><text>hi from wecom</text></xml>)
      encrypt = crypto.encrypt(xml, CORPID)
      sig = crypto.signature("1700000000", "n1", encrypt)
      body = %({"encrypt": "#{encrypt}"})

      result = adapter.handle_callback(post_request(body, sig))
      result.status.should eq(200)
      event = bus.receive?(2.seconds).should be_a(::Sebas::Platform::Bus::InboundMessage)
      event = event.as(::Sebas::Platform::Bus::InboundMessage)
      event.peer.should eq("userid:zhang")
      event.content.should eq("hi from wecom")

      # 重复投递（企微重试 3 次）：200 但不重复入总线
      result2 = adapter.handle_callback(post_request(body, sig))
      result2.status.should eq(200)
      bus.receive?(300.milliseconds).should be_nil
      store.close
      bus.close
      FileUtils.rm_rf(dir)
    end

    it "rejects bad signature with 401 (fail-closed)" do
      dir = Path[ENV["TEMP"], "sebas-wecom-spec", Random::Secure.hex(4)]
      FileUtils.rm_rf(dir)
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      adapter, bus = build_adapter(store)
      crypto = build_crypto
      encrypt = crypto.encrypt(%(<xml><msgid>9</msgid><text>x</text></xml>), CORPID)
      result = adapter.handle_callback(post_request(%({"encrypt": "#{encrypt}"}), "bad-sig"))
      result.status.should eq(401)
      bus.receive?(200.milliseconds).should be_nil
      store.close
      bus.close
      FileUtils.rm_rf(dir)
    end
  end
end
