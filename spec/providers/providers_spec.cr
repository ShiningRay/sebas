require "spec"
require "http/server"
require "json"
require "../../src/providers/providers"

module Sebas
  # 本地环回 HTTP server：按 path 分派 canned 响应并记录最后请求
  # （验收 #214：openai / anthropic wire 路径真实跑通，非只读源码推断）
  private def self.start_wire_server
    channel = Channel(HTTP::Request).new(1)
    body_channel = Channel(String).new(1)
    server = HTTP::Server.new do |context|
      body = context.request.body.try(&.gets_to_end) || ""
      channel.send(context.request)
      body_channel.send(body)
      case context.request.path
      when .ends_with?("/messages")
        context.response.content_type = "application/json"
        context.response.print %({"id": "msg_1", "type": "message", "role": "assistant", "content": [{"type": "text", "text": "anthropic-ok"}, {"type": "tool_use", "id": "t1", "name": "x", "input": {}}], "stop_reason": "end_turn"})
      else
        context.response.content_type = "application/json"
        context.response.print %({"choices": [{"message": {"role": "assistant", "content": "openai-ok"}}]})
      end
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    {address, channel, body_channel, server}
  end

  describe Providers do
    describe "resolve 决议（#214 纯函数）" do
      it "显式 provider：裸模型名直传，base_url/protocol 取 provider 配置" do
        cfg = Providers::ProviderCfg.new("sk-shared", "https://api.example.com", "openai-compatible")
        r = Providers.resolve("deepseek", nil, "deepseek-chat", cfg, nil, "pk", nil)
        r.name.should eq("deepseek")
        r.model.should eq("deepseek-chat")
        r.base_url.should eq("https://api.example.com")
        r.format.should eq("openai")
        r.api_key.should eq("pk")
      end

      it "遗留前缀推断与 provider_ref：剥掉与 provider 名相同的冗余前缀" do
        r = Providers.resolve(nil, nil, "deepseek/chat", nil, Providers.spec_for("deepseek"), nil, "ak")
        r.name.should eq("deepseek")
        r.model.should eq("chat")
        r.base_url.should eq("https://api.deepseek.com")
        r.format.should eq("openai")
        r.api_key.should eq("ak")

        r2 = Providers.resolve(nil, "deepseek", "deepseek/chat", nil, Providers.spec_for("deepseek"), nil, "ak")
        r2.model.should eq("chat")
      end

      it "openrouter 等自带斜杠的模型 ID 不被误剥（前缀≠provider 名）" do
        r = Providers.resolve("openrouter", nil, "openai/gpt-4o",
          Providers::ProviderCfg.new(nil, nil, "openai-compatible"), Providers.spec_for("openrouter"), "pk", nil)
        r.model.should eq("openai/gpt-4o")
        r.base_url.should eq("https://openrouter.ai/api/v1")
      end

      it "protocol=anthropic 映射 wire 格式；provider 配置 base_url 覆盖规格表" do
        r = Providers.resolve("anthropic", nil, "claude-sonnet-4",
          Providers::ProviderCfg.new(nil, "https://custom.example.com/v1", "anthropic"),
          Providers.spec_for("anthropic"), "pk", nil)
        r.base_url.should eq("https://custom.example.com/v1")
        r.format.should eq("anthropic")
      end

      it "fail-closed：无 provider 名 / base_url 双缺 / 未知 provider / 未知协议 / 密钥双缺" do
        expect_raises(Providers::ProviderResolveError, /does not encode a provider/) do
          Providers.resolve(nil, nil, "", nil, nil, nil, nil)
        end
        # 裸模型名无斜杠：前缀推断把整个名字当 provider，规格表缺失走 unknown 分支
        expect_raises(Providers::ProviderResolveError, /unknown provider 'chat'/) do
          Providers.resolve(nil, nil, "chat", nil, nil, nil, nil)
        end
        expect_raises(Providers::ProviderResolveError, /base_url missing/) do
          Providers.resolve("custom-p", nil, "m", Providers::ProviderCfg.new(nil, nil, "openai-compatible"), nil, "k", nil)
        end
        expect_raises(Providers::ProviderResolveError, /unknown provider 'ghost'/) do
          Providers.resolve("ghost", nil, "ghost/m", nil, nil, "k", nil)
        end
        expect_raises(Providers::ProviderResolveError, /unknown protocol 'pigeon'/) do
          Providers.resolve("p", nil, "m", Providers::ProviderCfg.new(nil, "https://x", "pigeon"), nil, "k", nil)
        end
        r = Providers.resolve("p", nil, "m", Providers::ProviderCfg.new(nil, "https://x", "openai-compatible"), nil, nil, nil)
        r.api_key.should be_nil
      end
    end

    describe "HttpProvider wire（#214）" do
      it "anthropic 协议路径真实跑通：/messages + x-api-key + system 提升 + 内容抽取" do
        address, req_channel, body_channel, server = start_wire_server
        provider = Providers::HttpProvider.new(
          Providers::Spec.new("anthropic-p", "http://#{address.address}:#{address.port}/v1", "anthropic"),
          "claude-sonnet-4", "sk-anthropic-test")
        messages = [
          Providers::Message.new("system", "be brief"),
          Providers::Message.new("user", "hello"),
          Providers::Message.new("assistant", "hi"),
          Providers::Message.new("user", "summarize"),
        ]
        completion = provider.complete(messages)
        completion.ok?.should be_true
        completion.text.should eq("anthropic-ok")

        request = req_channel.receive
        request.path.should eq("/v1/messages")
        request.headers["x-api-key"].should eq("sk-anthropic-test")
        request.headers["anthropic-version"].should eq("2023-06-01")
        body = JSON.parse(body_channel.receive)
        body["model"].should eq("claude-sonnet-4")
        body["system"].should eq("be brief")
        body["messages"].as_a.map(&.["role"].as_s).should eq(["user", "assistant", "user"])
        server.close
      end

      it "anthropic 首条 assistant 时补占位 user（角色交替硬约束）" do
        address, _req_channel, body_channel, server = start_wire_server
        provider = Providers::HttpProvider.new(
          Providers::Spec.new("anthropic-p", "http://#{address.address}:#{address.port}/v1", "anthropic"),
          "claude-sonnet-4", "sk")
        completion = provider.complete([Providers::Message.new("assistant", "cached prefix")])
        completion.ok?.should be_true
        body = JSON.parse(body_channel.receive)
        body["messages"].as_a.first["role"].should eq("user")
        server.close
      end

      it "openai 兼容路径：Bearer 头与 chat/completions 端点" do
        address, req_channel, _body_channel, server = start_wire_server
        provider = Providers::HttpProvider.new(
          Providers::Spec.new("deepseek", "http://#{address.address}:#{address.port}", "openai"),
          "deepseek-chat", "sk-openai-test")
        completion = provider.complete([Providers::Message.new("user", "hi")])
        completion.ok?.should be_true
        completion.text.should eq("openai-ok")
        request = req_channel.receive
        request.path.should eq("/chat/completions")
        request.headers["Authorization"].should eq("Bearer sk-openai-test")
        server.close
      end

      it "未实现的 wire 格式与 HTTP 错误显式转 Completion.error（不静默失败）" do
        provider = Providers::HttpProvider.new(Providers::Spec.new("x", "http://127.0.0.1:1", "grpc"), "m", "k")
        completion = provider.complete([Providers::Message.new("user", "hi")])
        completion.ok?.should be_false
        completion.error.should_not be_nil
        completion.error.to_s.should contain("not implemented")

        # 传输守卫（CWE-319）：远程明文 HTTP 拒发密钥；环回 http 放行（上方用例即环回）
        remote = Providers::HttpProvider.new(
          Providers::Spec.new("p", "http://relay.example.com:8080/v1", "openai"), "m", "sk-secret")
        insecure = remote.complete([Providers::Message.new("user", "hi")])
        insecure.ok?.should be_false
        insecure.error.to_s.should contain("plain HTTP")
        anthropic_insecure = Providers::HttpProvider.new(
          Providers::Spec.new("p", "http://relay.example.com/v1", "anthropic"), "m", "sk-secret").complete(
          [Providers::Message.new("user", "hi")]
        )
        anthropic_insecure.error.to_s.should contain("plain HTTP")

        _address, _req_channel, _body_channel, server = start_wire_server
        server_error = HTTP::Server.new do |context|
          context.response.status_code = 401
          context.response.print %({"error": "bad key"})
        end
        err_address = server_error.bind_tcp("127.0.0.1", 0)
        spawn { server_error.listen }
        failing = Providers::HttpProvider.new(
          Providers::Spec.new("p", "http://#{err_address.address}:#{err_address.port}", "openai"), "m", "k")
        result = failing.complete([Providers::Message.new("user", "hi")])
        result.ok?.should be_false
        result.error.should_not be_nil
        result.error.to_s.should contain("401")
        server.close
        server_error.close
      end
      it "transport guard：IPv6 环回剥方括号放行；http 未写端口按 80 而非 443（CodeRabbit）" do
        # URI#host 对 IPv6 返回 "[::1]"（Crystal 1.22 实测）——归一化后环回表命中，
        # guard 放行（无服务时错误是连接失败，绝不是 plain HTTP 拒发）
        v6 = Providers::HttpProvider.new(
          Providers::Spec.new("p", "http://[::1]:1/v1", "openai"), "m", "sk")
        v6_result = v6.complete([Providers::Message.new("user", "hi")])
        v6_result.ok?.should be_false
        v6_result.error.to_s.should_not contain("plain HTTP")

        # http 未写端口：endpoint_port 按 scheme 取 80（此前固定 443 会静默连错端口）
        no_port = Providers::HttpProvider.new(
          Providers::Spec.new("p", "http://127.0.0.1/v1", "openai"), "m", "sk")
        no_port_result = no_port.complete([Providers::Message.new("user", "hi")])
        no_port_result.ok?.should be_false
        no_port_result.error.to_s.should_not contain("plain HTTP")
      end
    end
  end
end
