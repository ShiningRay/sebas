require "spec"
require "../../src/platform/bus/bus"

# M3-WP7 扩展点定稿（m8 提案 §4.1）：InboundMessage.message_id 承载渠道侧消息
# 定位 ID（Telegram 的 message.message_id 等）。非破坏契约：尾置默认 nil，
# 既有五参位置构造（email/wecom/lark 适配器与回放路径）零改动。
describe Sebas::Platform::Bus::InboundMessage do
  it "constructs with five positional args and defaults message_id to nil" do
    message = Sebas::Platform::Bus::InboundMessage.new("evt-1", "email", "acc-1", "peer@x", "hello")
    message.message_id.should be_nil
  end

  it "carries message_id and round-trips it through JSON" do
    message = Sebas::Platform::Bus::InboundMessage.new("evt-2", "telegram", "bot-1", "12345", "hi", "msg-42")
    message.message_id.should eq("msg-42")
    parsed = Sebas::Platform::Bus::InboundMessage.from_json(message.to_json)
    parsed.should eq(message)
    parsed.message_id.should eq("msg-42")
  end

  it "parses legacy JSON without message_id" do
    message = Sebas::Platform::Bus::InboundMessage.from_json(%({"event_id":"e","channel_type":"email","account_id":"a","peer":"p","content":"c"}))
    message.message_id.should be_nil
  end
end
