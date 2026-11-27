require "spec"
require "../support/plugins_spec_helper"

# Runner 验收语义（M3-WP4，#16）：协议往返、崩溃隔离、超时拦截、协议违规
# 拒绝、未声明/未注册/重复注册拒绝。解释器可注入（真 mruby 或 CRuby shim）。
interp = PluginSpecSupport.interpreter

module Sebas
  describe "plugin runner（M3-WP4 验收）" do
    if interp
      it "动作往返：payload 注入 → handler 返回 JSON-like 结果" do
        dispatch = PluginSpecSupport.make_dispatch(interp.as(Array(String)))
        outcome = dispatch.call_action("echo", "ping", JSON.parse("{}"),
          JSON.parse(%({"msg":"hello"})))
        outcome.ok.should be_true
        outcome.value.as(JSON::Any)["pong"].as_s.should eq("hello")
      end

      it "capability 往返：声明内的 capability 调用 driver 并回传结果" do
        dispatch = PluginSpecSupport.make_dispatch(interp.as(Array(String)))
        outcome = dispatch.call_action("echo", "ping", JSON.parse("{}"),
          JSON.parse(%({"cap":"test.echo","cap_params":{"x":7}})))
        outcome.ok.should be_true
        outcome.value.as(JSON::Any)["cap_result"]["x"].as_i.should eq(7)
      end

      it "capability driver 失败：结构化错误交付插件，插件转结构化结果" do
        dispatch = PluginSpecSupport.make_dispatch(interp.as(Array(String)))
        outcome = dispatch.call_action("echo", "ping", JSON.parse("{}"),
          JSON.parse(%({"cap":"test.fail"})))
        outcome.ok.should be_false
        outcome.error_code.should eq("capability_failed")
        outcome.error_message.to_s.should contain("driver exploded")
      end

      it "跨 scope capability 拒绝：未在 manifest 声明即宿主拒绝，不调 driver" do
        dispatched = false
        dispatch = PluginSpecSupport.make_dispatch(interp.as(Array(String)))
        dispatch.runner.capability_handler = ->(_plugin : ::Sebas::Plugins::LoadedPlugin, _capability : String, _params : JSON::Any) do
          dispatched = true
          JSON::Any.new(nil)
        end
        outcome = dispatch.call_action("echo", "ping", JSON.parse("{}"),
          JSON.parse(%({"cap":"memory_driver.write"})))
        outcome.ok.should be_false
        outcome.error_code.should eq("capability_not_authorized")
        dispatched.should be_false # 越权调用绝不触达 driver
      end

      it "未注册 handler 拒绝（manifest 声明但本次进程未登记）" do
        dispatch = PluginSpecSupport.make_dispatch(interp.as(Array(String)))
        outcome = dispatch.call_action("unregistered", "ping", JSON.parse("{}"), JSON.parse("{}"))
        outcome.ok.should be_false
        outcome.error_code.should eq("handler_not_registered")
      end

      it "重复注册拒绝（结构化 duplicate_registration，非崩溃）" do
        dispatch = PluginSpecSupport.make_dispatch(interp.as(Array(String)))
        outcome = dispatch.call_action("duplicate-reg", "ping", JSON.parse("{}"), JSON.parse("{}"))
        outcome.ok.should be_false
        outcome.error_code.should eq("duplicate_registration")
      end

      it "额外注册拒绝：注册集超出 manifest 声明即拒绝该次调用" do
        dispatch = PluginSpecSupport.make_dispatch(interp.as(Array(String)))
        outcome = dispatch.call_action("undeclared-reg", "ping", JSON.parse("{}"), JSON.parse("{}"))
        outcome.ok.should be_false
        outcome.error_code.should eq("undeclared_registration")
        outcome.error_message.to_s.should contain("extra")
      end

      it "插件崩溃只影响该次调用并返回结构化错误" do
        dispatch = PluginSpecSupport.make_dispatch(interp.as(Array(String)))
        outcome = dispatch.call_action("crash", "boom", JSON.parse("{}"), JSON.parse("{}"))
        outcome.ok.should be_false
        outcome.error_code.should eq("plugin_crash")
        # 崩溃隔离：同一插件立即重试仍能得到结构化结果（不卡宿主、不串状态）
        again = dispatch.call_action("crash", "boom", JSON.parse("{}"), JSON.parse("{}"))
        again.error_code.should eq("plugin_crash")
      end

      it "死循环被 watchdog 超时终止（manifest 300ms，不卡宿主）" do
        dispatch = PluginSpecSupport.make_dispatch(interp.as(Array(String)))
        started = Time.instant
        outcome = dispatch.call_action("spin", "spin", JSON.parse("{}"), JSON.parse("{}"))
        elapsed = (Time.instant - started).total_milliseconds
        outcome.ok.should be_false
        outcome.error_code.should eq("timeout")
        elapsed.should be < 5_000
      end

      it "协议违规拒绝：顶层伪造 result 帧 → 后续 registered 帧乱序即拒绝" do
        dispatch = PluginSpecSupport.make_dispatch(interp.as(Array(String)))
        outcome = dispatch.call_action("noisy", "ping", JSON.parse("{}"), JSON.parse("{}"))
        outcome.ok.should be_false
        outcome.error_code.should eq("protocol_violation")
      end

      it "合成程序守卫：无请求输入 → 结构化 no_request（不执行插件代码）" do
        program_path = Path[Dir.tempdir] / "sebas-prelude-guard-#{Random::Secure.hex(4)}.rb"
        File.write(program_path, ::Sebas::Plugins::Prelude.compose("on_action 'x' do |_p|\nend\n"))
        process = ::Process.new(interp.as(Array(String)).first, interp.as(Array(String))[1..] + [program_path.to_s],
          input: ::Process::Redirect::Close,
          output: ::Process::Redirect::Pipe,
          error: ::Process::Redirect::Close)
        lines = Array(String).new
        while line = process.output.gets
          lines << line.chomp
        end
        status = process.wait
        File.delete(program_path)
        status.success?.should be_true
        frames = lines.map { |row| JSON.parse(row).as_h }
        result = frames.find! { |frame| frame["type"]?.try(&.as_s?) == "result" }
        result["ok"].as_bool.should be_false
        result["error"]["code"].as_s.should eq("no_request")
      end

      it "合成程序守卫：坏 JSON 请求 → 结构化 invalid_request" do
        program_path = Path[Dir.tempdir] / "sebas-prelude-guard-#{Random::Secure.hex(4)}.rb"
        File.write(program_path, ::Sebas::Plugins::Prelude.compose(""))
        process = ::Process.new(interp.as(Array(String)).first, interp.as(Array(String))[1..] + [program_path.to_s],
          input: ::Process::Redirect::Pipe,
          output: ::Process::Redirect::Pipe,
          error: ::Process::Redirect::Close)
        process.input.puts("not-json-at-all")
        process.input.close
        lines = Array(String).new
        while line = process.output.gets
          lines << line.chomp
        end
        process.wait
        File.delete(program_path)
        frames = lines.map { |row| JSON.parse(row).as_h }
        result = frames.find! { |frame| frame["type"]?.try(&.as_s?) == "result" }
        result["error"]["code"].as_s.should eq("invalid_request")
      end
    else
      pending "runner specs 需要解释器：SEBAS_PLUGIN_INTERPRETER 或 PATH 上的 ruby（真实沙箱验收在 mruby-sandbox workflow）"
    end
  end
end
