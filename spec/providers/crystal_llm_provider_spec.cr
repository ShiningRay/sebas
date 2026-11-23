require "spec"
require "../../src/sebas"
require "http/server"

describe Sebas::Providers::CrystalLLMProvider do
  it "将消息转成 crystal-llm 调用并返回文本" do
    server = HTTP::Server.new do |context|
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
    ensure
      server.close
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
