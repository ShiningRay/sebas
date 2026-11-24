require "spec"
require "file_utils"
require "../../src/agents/agents"
require "../../src/platform/config/loader"

def dual_env
  dir = Path[Dir.tempdir, "sebas-dual-spec", Random::Secure.hex(4)]
  FileUtils.mkdir_p(dir / "agents")
  registry = ::Sebas::Agents::AgentRegistry.new(dir / "agents")
  {dir, registry}
end

module Sebas
  describe "注册双轨统一（M4.4-WP1）" do
    it "双轨互查：config 定义的 agent 在目录轨均有实例（sync 幂等补建）" do
      _dir, registry = dual_env
      config = ::Sebas::Platform::Config::Loader.from_content(%(agents:\n  alpha: { model: fake/a }\n  beta: { model: fake/b }\n))
      view = ::Sebas::Agents::RegistryDualView.new(registry, config.agents)
      # 存量只读兼容不强制迁移：sync 幂等补默认 SOUL.md（已有不覆盖）
      view.sync_config_agents
      view.consistent_for_config_agents?.should be_true
      snapshot = view.snapshot
      snapshot.size.should eq(2)
      alpha = snapshot.find { |v| v.id == "alpha" }
      alpha.should be_a(::Sebas::Agents::RegistryDualView::AgentView)
      alpha = alpha.as(::Sebas::Agents::RegistryDualView::AgentView)
      alpha.in_config.should be_true
      alpha.in_registry.should be_true
      alpha.model.should eq("fake/a")
    end

    it "persona_file 悬空引用：Loader.load 报错可读（fail-fast）" do
      dir = Path[Dir.tempdir, "sebas-dual-spec", "dangling-#{Random::Secure.hex(4)}"]
      FileUtils.mkdir_p(dir)
      config_path = dir / "config.yaml"
      File.write(config_path, %(agents:\n  main: { model: fake/a, persona_file: missing/soul.md }\n))
      ex = expect_raises(::Sebas::Platform::Config::ValidationError) do
        ::Sebas::Platform::Config::Loader.load(config_path.to_s)
      end
      ex.errors.join("\n").should contain("persona_file not found")
    end

    it "目录轨独有 agent（config 轨缺失）：只读兼容列明不报错" do
      _dir, registry = dual_env
      registry.get_or_create("legacy-agent") # 存量目录轨（无 config 定义）
      config = ::Sebas::Platform::Config::Loader.from_content(%(agents:\n  main: { model: fake/a }\n))
      view = ::Sebas::Agents::RegistryDualView.new(registry, config.agents)
      snapshot = view.snapshot
      snapshot.map(&.id).should contain("legacy-agent")
      legacy = snapshot.find { |v| v.id == "legacy-agent" }
      legacy.should be_a(::Sebas::Agents::RegistryDualView::AgentView)
      legacy = legacy.as(::Sebas::Agents::RegistryDualView::AgentView)
      legacy.in_config.should be_false # config 轨缺失仅列明（只读兼容）
      legacy.in_registry.should be_true
    end

    it "skills 字段补齐：非空校验 + 字段可读（M4.4-WP2 消费前置）" do
      config = ::Sebas::Platform::Config::Loader.from_content(%(agents:\n  main: { model: fake/a, skills: [code, ops] }\n))
      config.agents["main"].skills.should eq(["code", "ops"])
      ex = expect_raises(::Sebas::Platform::Config::ValidationError) do
        ::Sebas::Platform::Config::Loader.from_content(%(agents:\n  main: { model: fake/a, skills: [code, ""] }\n))
      end
      ex.errors.join("\n").should contain("skills entry must not be empty")
    end
  end
end
