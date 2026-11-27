require "spec"
require "../../src/plugins/protocol"
require "../support/plugins_spec_helper"

module Sebas
  describe "plugin protocol（M3-WP4 帧协议）" do
    it "request 帧含全部必填字段，idempotency_key 可省略" do
      request = PluginSpecSupport.request("remember", JSON.parse({"text" => "hi"}.to_json))
      frame = JSON.parse(request.to_frame).as_h
      frame["protocol_version"].as_i.should eq(1)
      frame["request_id"].as_s.should eq(request.request_id)
      frame["plugin_id"].as_s.should eq("spec")
      frame["action"].as_s.should eq("remember")
      frame["payload"]["text"].as_s.should eq("hi")
      (frame["idempotency_key"]?.nil?).should be_true
    end

    it "request 帧带 idempotency_key 时包含该字段" do
      request = PluginSpecSupport.request("remember")
      keyed = request.class.new(request.request_id, request.plugin_id, request.action,
        request.context, request.payload, request.config, "send:acc:evt")
      JSON.parse(keyed.to_frame)["idempotency_key"].as_s.should eq("send:acc:evt")
    end

    it "registered 帧解析：actions/hooks 字符串数组" do
      frame = ::Sebas::Plugins::Protocol.parse_frame(
        %({"type":"registered","actions":["ping"],"hooks":["gateway.start"]}))
      frame.should be_a(::Sebas::Plugins::Protocol::RegisteredFrame)
      registered = frame.as(::Sebas::Plugins::Protocol::RegisteredFrame)
      registered.actions.should eq(["ping"])
      registered.hooks.should eq(["gateway.start"])
    end

    it "capability_call 帧解析与字段闭集" do
      frame = ::Sebas::Plugins::Protocol.parse_frame(
        %({"type":"capability_call","call_id":"1","capability":"test.echo","params":{"x":1}}))
      call = frame.should be_a(::Sebas::Plugins::Protocol::CapabilityCallFrame)
      call.call_id.should eq("1")
      call.capability.should eq("test.echo")
      call.params.as(JSON::Any)["x"].as_i.should eq(1)

      expect_raises(::Sebas::Plugins::ProtocolError, "unknown field") do
        ::Sebas::Plugins::Protocol.parse_frame(
          %({"type":"capability_call","call_id":"1","capability":"c","params":{},"op":"write"}))
      end
    end

    it "result 帧：ok/err 两种形态与闭集校验" do
      frame = ::Sebas::Plugins::Protocol.parse_frame(
        %({"type":"result","request_id":"r1","ok":true,"value":{"a":1}}))
      ok = frame.should be_a(::Sebas::Plugins::Protocol::ResultFrame)
      ok.ok?.should be_true
      ok.value.as(JSON::Any)["a"].as_i.should eq(1)

      err_frame = ::Sebas::Plugins::Protocol.parse_frame(
        %({"type":"result","request_id":"r1","ok":false,"error":{"code":"boom","message":"x"}}))
      err = err_frame.should be_a(::Sebas::Plugins::Protocol::ResultFrame)
      err.ok?.should be_false
      err.error_code.should eq("boom")
      err.error_message.should eq("x")

      expect_raises(::Sebas::Plugins::ProtocolError, "error object") do
        ::Sebas::Plugins::Protocol.parse_frame(%({"type":"result","request_id":"r1","ok":false}))
      end
      expect_raises(::Sebas::Plugins::ProtocolError, "unknown field") do
        ::Sebas::Plugins::Protocol.parse_frame(%({"type":"result","request_id":"r1","ok":true,"extra":1}))
      end
    end

    it "未知类型 / 非 JSON / 缺 type / 超限帧全部拒绝" do
      expect_raises(::Sebas::Plugins::ProtocolError, "unknown frame type") do
        ::Sebas::Plugins::Protocol.parse_frame(%({"type":"mystery"}))
      end
      expect_raises(::Sebas::Plugins::ProtocolError, "not a JSON object") do
        ::Sebas::Plugins::Protocol.parse_frame("hello world")
      end
      expect_raises(::Sebas::Plugins::ProtocolError, "missing 'type'") do
        ::Sebas::Plugins::Protocol.parse_frame(%({"action":"ping"}))
      end
      big = "x" * (::Sebas::Plugins::Protocol::MAX_FRAME + 1)
      expect_raises(::Sebas::Plugins::ProtocolError, "exceeds") do
        ::Sebas::Plugins::Protocol.parse_frame(big)
      end
    end

    it "capability_result 应答帧构造（ok / error 两形态）" do
      ok = ::Sebas::Plugins::Protocol.capability_result("1", true, JSON.parse(%({"id":"m"})), nil, nil)
      parsed = JSON.parse(ok)
      parsed["type"].as_s.should eq("capability_result")
      parsed["call_id"].as_s.should eq("1")
      parsed["ok"].as_bool.should be_true
      parsed["result"]["id"].as_s.should eq("m")

      err = ::Sebas::Plugins::Protocol.capability_result("2", false, nil, "driver_down", "unreachable")
      parsed = JSON.parse(err)
      parsed["ok"].as_bool.should be_false
      parsed["error"]["code"].as_s.should eq("driver_down")
      (parsed["result"]?.nil?).should be_true
    end
  end
end
