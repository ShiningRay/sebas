require "spec"
require "http/server"
require "../../src/channels/common/token_provider"

# 假 token 服务器：记录调用次数并按脚本应答（顶层助手；describe 块内不能声明 def）
def with_token_server(script : Array(String), &) : Nil
  calls = Atomic(Int32).new(0)
  server = HTTP::Server.new do |ctx|
    idx = calls.add(1)
    ctx.response.content_type = "application/json"
    ctx.response.print(script[Math.min(idx, script.size - 1)])
  end
  addr = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  begin
    yield addr.port, -> { calls.get }
  ensure
    server.close
  end
end

module Sebas
  describe "channel token providers (M1-WP3)" do
    it "fetches wecom gettoken and caches within validity (重复获取返回相同 token)" do
      with_token_server([
        %({"errcode":0,"errmsg":"ok","access_token":"tok-1","expires_in":7200}),
      ]) do |port, calls|
        provider = Channels::Common::WecomTokenProvider.new("corp", "secret", base_url: "http://127.0.0.1:#{port}")
        token = provider.token
        token.value.should eq("tok-1")
        token.expires_at.should be > Time.utc + 1.hours
        provider.token.value.should eq("tok-1")
        calls.call.should eq(1) # 缓存命中：仅一次网络获取
        provider.invalidate     # 失效重取（§14 M1 验收第 3 条的前半）
        provider.token.value.should eq("tok-1")
        calls.call.should eq(2)
      end
    end

    it "fails typed on wecom errcode" do
      with_token_server([%({"errcode":40001,"errmsg":"invalid credential"})]) do |port, _|
        provider = Channels::Common::WecomTokenProvider.new("corp", "bad", base_url: "http://127.0.0.1:#{port}")
        expect_raises(Channels::Common::TokenFetchError, /40001/) do
          provider.token
        end
      end
    end

    it "fetches lark tenant_access_token and caches within validity" do
      with_token_server([
        %({"code":0,"msg":"ok","tenant_access_token":"t-abc","expire":7200}),
      ]) do |port, calls|
        provider = Channels::Common::LarkTokenProvider.new("app", "secret", base_url: "http://127.0.0.1:#{port}")
        provider.token.value.should eq("t-abc")
        provider.token.value.should eq("t-abc")
        calls.call.should eq(1) # 有效期内缓存命中
      end
    end

    it "renews early when lark expire is shorter than the refresh buffer" do
      with_token_server([
        %({"code":0,"msg":"ok","tenant_access_token":"t-1","expire":600}),
        %({"code":0,"msg":"ok","tenant_access_token":"t-2","expire":600}),
      ]) do |port, calls|
        provider = Channels::Common::LarkTokenProvider.new("app", "secret", base_url: "http://127.0.0.1:#{port}")
        provider.token.expires_at.should be < Time.utc + 11.minutes # 以 expires_in 为准勿硬编码
        provider.token.value.should eq("t-2")                       # 剩余 10min < 30min buffer → 提前刷新
        calls.call.should eq(2)
      end
    end

    it "fails typed on lark error code" do
      with_token_server([%({"code":10003,"msg":"invalid app_id"})]) do |port, _|
        provider = Channels::Common::LarkTokenProvider.new("bad", "x", base_url: "http://127.0.0.1:#{port}")
        expect_raises(Channels::Common::TokenFetchError, /10003/) do
          provider.token
        end
      end
    end

    it "support refresh-buffer based early renewal (提前刷新)" do
      calls = Atomic(Int32).new(0)
      provider = Channels::Common::CachedTokenProvider.new(refresh_buffer: 30.minutes) do
        calls.add(1)
        Channels::Common::Token.new("t#{calls.get}", Time.utc + 20.minutes) # 剩余 < buffer → 提前刷新
      end
      provider.token.value.should eq("t1")
      provider.token.value.should eq("t2") # 临期提前刷新，非等过期
      calls.get.should eq(2)
    end
  end
end
