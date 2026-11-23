require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/providers/fake_provider"
require "../../support/gateway_spec_helper"

module Sebas
  describe "secrets 收敛（M4.2-WP4，semantics §5.3）" do
    it "配置明文 api_key 迁 vault 且配置树抹除（幂等可重跑）" do
      dir = gateway_tmp_dir("secrets-migrate")
      yaml = <<-YAML
        agents:
          main: { model: fake/chat, api_key: sk-secret-123 }
        YAML
      config = ::Sebas::Platform::Config::Loader.from_content(yaml)
      config.agents["main"].api_key.should eq("sk-secret-123")

      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        ::Sebas::Providers::FakeProvider.new("fake", ["ok"])
      end

      # 配置树抹除：明文不出现在运行期配置
      config.agents["main"].api_key.should be_nil
      # vault 承接：按 (agent, name, api_key) 命名空间取回原值
      gateway.vault.get("agent", "main", "api_key").should eq("sk-secret-123")
      gateway.shutdown

      # 幂等可重跑：复用已抹除明文的同一 config 对象重建 Gateway →
      # 从 vault 恢复凭据映射（provider 仍能拿到 key）、vault 值稳定
      gateway2 = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        ::Sebas::Providers::FakeProvider.new("fake", ["ok"])
      end
      config.agents["main"].api_key.should be_nil
      gateway2.vault.get("agent", "main", "api_key").should eq("sk-secret-123")
      gateway2.shutdown
    end

    it "provider 工厂经热更新收到 vault 解析出的 key（无凭据直读路径：key 走参数注入）" do
      dir = gateway_tmp_dir("secrets-factory")
      yaml = <<-YAML
        agents:
          main: { model: fake/chat, api_key: sk-vault-key-9 }
        YAML
      config_path = dir / "config.yaml"
      File.write(config_path, yaml)
      config = ::Sebas::Platform::Config::Loader.from_content(yaml)
      received = [] of String?
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir, config_path.to_s) do |_agent, key|
        received << key
        ::Sebas::Providers::FakeProvider.new("fake", ["ok"])
      end
      # 触发 provider 构建（懒构造：apply_config 经 factory.call 注入 vault key）
      gateway.trigger_reload
      gateway.shutdown
      # wrapped factory 把 vault key 注入用户工厂——provider 拿到凭据但配置树无明文
      received.compact.should contain("sk-vault-key-9")
      config.agents["main"].api_key.should be_nil
    end

    it "热更新带入的明文 api_key 同样收敛（trigger_reload 路径）" do
      dir = gateway_tmp_dir("secrets-hotreload")
      yaml = <<-YAML
        agents:
          main: { model: fake/chat }
        YAML
      config_path = dir / "config.yaml"
      File.write(config_path, yaml)
      config = ::Sebas::Platform::Config::Loader.from_content(yaml)
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir, config_path.to_s) do |_agent, _key|
        ::Sebas::Providers::FakeProvider.new("fake", ["ok"])
      end
      # 热更新：改配置文件带明文 api_key → trigger_reload → apply_config 迁移
      hot_yaml = <<-YAML
        agents:
          main: { model: fake/chat, api_key: sk-hot-reload-7 }
        YAML
      File.write(config_path, hot_yaml)
      gateway.trigger_reload
      gateway.config.agents["main"].api_key.should be_nil
      gateway.vault.get("agent", "main", "api_key").should eq("sk-hot-reload-7")
      gateway.shutdown
    end
  end
end
