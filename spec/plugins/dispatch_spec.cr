require "spec"
require "file_utils"
require "../support/plugins_spec_helper"

# 精确派发验收（M3-WP4，#16）：宿主派发闸 + hook 订阅索引 + 生命周期边界。
interp = PluginSpecSupport.interpreter

module Sebas
  describe "plugin dispatch（M3-WP4 精确派发）" do
    it "未声明 action 拒绝：宿主不 spawn 解释器" do
      registry = ::Sebas::Plugins::Registry.new
      dispatch = ::Sebas::Plugins::Dispatch.new(registry,
        ::Sebas::Plugins::Runner.new(["definitely-not-an-interpreter"]))
      outcome = dispatch.call_action("echo", "hidden", JSON.parse("{}"), JSON.parse("{}"))
      outcome.ok.should be_false
      outcome.error_code.should eq("plugin_not_found")

      registry.load_dir(PluginSpecSupport::FIXTURES)
      outcome = dispatch.call_action("echo", "hidden", JSON.parse("{}"), JSON.parse("{}"))
      outcome.ok.should be_false
      outcome.error_code.should eq("action_not_declared")
    end

    it "hook 订阅索引精确派发：只有声明该 hook 的插件收到，不群发" do
      interp2 = interp
      unless interp2
        pending "需要解释器"
        next
      end
      dispatch = PluginSpecSupport.make_dispatch(interp2)
      outcomes = dispatch.call_hook("memory.remember.before", JSON.parse("{}"),
        JSON.parse(%({"entry":{"text":"hello"}})))
      outcomes.size.should eq(1) # 夹具中只有 hooky 声明该 hook
      plugin_id, outcome = outcomes[0]
      plugin_id.should eq("hooky")
      outcome.ok.should be_true
      outcome.value.as(JSON::Any)["ran"].as_s.should eq("hook")
    end

    it "生命周期边界：install 只经显式调用，hook 派发永不触达" do
      interp2 = interp
      unless interp2
        pending "需要解释器"
        next
      end
      dispatch = PluginSpecSupport.make_dispatch(interp2)
      # hook 派发路径返回的是 hook handler 的结果——install/enable/disable
      # 动作体没有被执行（若执行会返回 {"ran":"install"} 等）
      outcomes = dispatch.call_hook("memory.remember.before", JSON.parse("{}"),
        JSON.parse(%({"entry":{"text":"hello"}})))
      outcomes.each do |(_, outcome)|
        outcome.value.as(JSON::Any)["ran"].as_s.should eq("hook")
      end
      # 生命周期动作只由宿主显式调用（§12.3）
      outcome = dispatch.call_action("hooky", "install", JSON.parse("{}"), JSON.parse("{}"))
      outcome.ok.should be_true
      outcome.value.as(JSON::Any)["ran"].as_s.should eq("install")
    end

    it "示例插件可装载：examples 目录两插件 manifest 全部合法" do
      registry = ::Sebas::Plugins::Registry.new
      report = registry.load_dir(PluginSpecSupport::EXAMPLES_DIR)
      report.errors.should eq([] of String)
      report.loaded.should eq(["memory-guard", "remote-memory"])
    end

    it "registry 容错：缺 manifest / 坏 manifest / 重 id 逐份可读报错" do
      dir = Path[Dir.tempdir, "sebas-plugin-registry-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir / "no-manifest")
      FileUtils.mkdir_p(dir / "bad-id")
      File.write(dir / "bad-id" / "manifest.json", {"schema_version" => 1, "id" => "Bad ID",
                                                    "version" => "1.0.0", "api_version" => "1"}.to_json)
      FileUtils.mkdir_p(dir / "dup")
      File.write(dir / "dup" / "manifest.json", {"schema_version" => 1, "id" => "echo", "version" => "1.0.0",
                                                 "api_version" => "1", "actions" => ["ping"]}.to_json)
      File.write(dir / "dup" / "plugin.rb", "on_action \"ping\" do |_p|\nend\n")
      FileUtils.mkdir_p(dir / "echo")
      File.write(dir / "echo" / "manifest.json", {"schema_version" => 1, "id" => "echo", "version" => "1.0.0",
                                                  "api_version" => "1", "actions" => ["ping"]}.to_json)
      File.write(dir / "echo" / "plugin.rb", "on_action \"ping\" do |_p|\nend\n")
      FileUtils.mkdir_p(dir / "no-entry")
      File.write(dir / "no-entry" / "manifest.json", {"schema_version" => 1, "id" => "no-entry",
                                                      "version" => "1.0.0", "api_version" => "1",
                                                      "actions" => ["x"]}.to_json)
      registry = ::Sebas::Plugins::Registry.new
      report = registry.load_dir(dir)
      report.loaded.should eq(["echo"])
      registry.plugin("echo").should_not be_nil
      report.errors.size.should eq(4)
      report.errors.any?(&.includes?("no-manifest")).should be_true
      report.errors.any?(&.includes?("id must be lowercase")).should be_true
      report.errors.any?(&.includes?("duplicate plugin id")).should be_true
      report.errors.any?(&.includes?("entrypoint")).should be_true
    end
  end
end
