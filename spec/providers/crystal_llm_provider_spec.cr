require "spec"
require "../../src/sebas"
require "http/server"

# 记录 mock server 收到的请求，用于断言适配层行为
private record RecordedRequest, method : String, path : String, body : String, headers : HTTP::Headers

describe Sebas::Providers::CrystalLLMProvider do
  it "将消息转成 crystal-llm 调用并返回文本" do
    requests = [] of RecordedRequest
    server = HTTP::Server.new do |context|
      body = context.request.body.try(&.gets_to_end) || ""
      requests << RecordedRequest.new(context.request.method, context.request.path, body, context.request.headers)
      context.response.content_type = "application/json"
      context.response << %({"id":"chatcmpl-1","object":"chat.completion","created":1,"model":"gpt-4o-mini","choices":[{"index":0,"message":{"role":"assistant","content":"pong"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}})
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      base = "http://#{address}/v1"
      provider = Sebas::Providers::CrystalLLMProvider.new(
        model: "gpt-4o-mini", provider: "openai", api_key: "sk-test", api_base: base)
      result = provider.complete([Sebas::Providers::Message.new("user", "ping")])
      result.ok?.should be_true
      result.text.should eq("pong")

      # 断言请求方法、路径、认证头
      requests.size.should eq(1)
      req = requests.first
      req.method.should eq("POST")
      req.path.should eq("/v1/chat/completions")
      req.headers["Authorization"].should eq("Bearer sk-test")
      req.headers["Content-Type"]?.try(&.should contain("application/json"))

      # 断言请求体包含正确的 model 和消息顺序
      parsed = JSON.parse(req.body)
      parsed["model"].should eq("gpt-4o-mini")
      parsed["messages"].as_a.size.should eq(1)
      parsed["messages"][0]["role"].should eq("user")
      parsed["messages"][0]["content"].should eq("ping")
    ensure
      server.close
    end
  end

  it "多实例配置隔离：不同 key 和 base 不串台" do
    requests_a = [] of RecordedRequest
    requests_b = [] of RecordedRequest

    server_a = HTTP::Server.new do |context|
      body = context.request.body.try(&.gets_to_end) || ""
      requests_a << RecordedRequest.new(context.request.method, context.request.path, body, context.request.headers)
      context.response.content_type = "application/json"
      context.response << %({"id":"a","object":"chat.completion","created":1,"model":"m-a","choices":[{"index":0,"message":{"role":"assistant","content":"pong-a"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}})
    end
    server_b = HTTP::Server.new do |context|
      body = context.request.body.try(&.gets_to_end) || ""
      requests_b << RecordedRequest.new(context.request.method, context.request.path, body, context.request.headers)
      context.response.content_type = "application/json"
      context.response << %({"id":"b","object":"chat.completion","created":1,"model":"m-b","choices":[{"index":0,"message":{"role":"assistant","content":"pong-b"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}})
    end

    addr_a = server_a.bind_tcp("127.0.0.1", 0)
    addr_b = server_b.bind_tcp("127.0.0.1", 0)
    spawn { server_a.listen }
    spawn { server_b.listen }
    begin
      provider_a = Sebas::Providers::CrystalLLMProvider.new(
        model: "m-a", provider: "openai", api_key: "sk-a", api_base: "http://#{addr_a}/v1")
      provider_b = Sebas::Providers::CrystalLLMProvider.new(
        model: "m-b", provider: "openai", api_key: "sk-b", api_base: "http://#{addr_b}/v1")

      # 交错调用
      result_a = provider_a.complete([Sebas::Providers::Message.new("user", "ping-a")])
      result_b = provider_b.complete([Sebas::Providers::Message.new("user", "ping-b")])

      result_a.ok?.should be_true
      result_a.text.should eq("pong-a")
      result_b.ok?.should be_true
      result_b.text.should eq("pong-b")

      # 验证请求发到正确的 server
      requests_a.size.should eq(1)
      requests_b.size.should eq(1)

      # 验证 key 隔离
      requests_a.first.headers["Authorization"].should eq("Bearer sk-a")
      requests_b.first.headers["Authorization"].should eq("Bearer sk-b")

      # 验证 model 隔离
      JSON.parse(requests_a.first.body)["model"].should eq("m-a")
      JSON.parse(requests_b.first.body)["model"].should eq("m-b")

      # 验证消息内容隔离
      JSON.parse(requests_a.first.body)["messages"][0]["content"].should eq("ping-a")
      JSON.parse(requests_b.first.body)["messages"][0]["content"].should eq("ping-b")
    ensure
      server_a.close
      server_b.close
    end
  end

  it "未配置的 provider 返回错误 Completion 而不是抛异常" do
    provider = Sebas::Providers::CrystalLLMProvider.new(
      model: "m", provider: "unsupported", api_key: "k")
    result = provider.complete([Sebas::Providers::Message.new("user", "hi")])
    result.ok?.should be_false
    result.error.should_not be_nil
    (result.error || "").should contain("unsupported crystal_llm provider")
  end

  it "空 api key 返回错误 Completion" do
    provider = Sebas::Providers::CrystalLLMProvider.new(
      model: "m", provider: "openai", api_key: "")
    result = provider.complete([Sebas::Providers::Message.new("user", "hi")])
    result.ok?.should be_false
    result.error.should_not be_nil
    (result.error || "").should contain("missing api key")
  end
end
