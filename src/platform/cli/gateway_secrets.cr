# Gateway secrets 收敛（M4.2-WP4，#49，自 gateway.cr 拆分）：
# 配置明文 api_key 迁 vault（幂等）+ 配置树抹除 + provider 解析键记录。
# 本 module 由 Gateway include，方法直接访问宿主实例变量——拆分只改代码
# 组织，不改行为（同 gateway_dispatch.cr 模式）。
module Sebas
  module Platform
    module CLI
      module GatewaySecrets
        # secrets vault（M4.2-WP4）：AES-256-GCM 静态加密（主密钥 OS keyring，
        # 降级 0600 主密钥文件）；分身执行面无凭据直读路径（provider 句柄封装）。
        getter vault : Keys::EncryptedFileVault
        @provider_factory : Proc(Config::AgentConfig, String?, Providers::Provider)
        @provider_keys : Hash(String, String) = Hash(String, String).new
        # agent 名 → 最新实例（migrate_secrets 维护）：wrapped factory 按实例
        # 身份反查名字，注入 vault 解析 key（热更新换 @config 引用不依赖）。
        @agent_instances : Hash(String, Config::AgentConfig) = Hash(String, Config::AgentConfig).new

        # 工厂包装：按实例身份反查 agent 名注入 vault 解析 key（热更新换
        # @config 引用不依赖 @agent_instances 之外的状态）。
        def wire_secret_factory(original_factory : Proc(Config::AgentConfig, String?, Providers::Provider)) : Proc(Config::AgentConfig, String?, Providers::Provider)
          ->(agent : Config::AgentConfig, key : String?) {
            name = @agent_instances.find { |_, candidate| candidate.same?(agent) }.try(&.[0])
            original_factory.call(agent, name ? (@provider_keys[name]? || key) : key)
          }
        end

        # 平台 keyring 装配：Windows Credential Manager（M1-WP7 FFI spike 实测），
        # 非 Windows nil → vault 主密钥文件 0600 降级。
        private def platform_keyring : ::Sebas::Platform::Keys::WinCredentialStore?
          {% if flag?(:windows) %}
            ::Sebas::Platform::Keys::WinCredentialStore.new
          {% else %}
            nil
          {% end %}
        end

        # 明文凭据迁移（M4.2-WP4 §5.3，幂等可重跑）：配置树 api_key 非空 →
        # 写 vault（覆盖写幂等）+ 内存抹除（setter 置 nil）+ 记录 provider 解析
        # 键。热更新路径（apply_config）同样走此收敛。
        def migrate_secrets(config : Config::Config) : Nil
          config.agents.each do |name, agent|
            @agent_instances[name] = agent
            key = agent.api_key
            if key
              vault.set("agent", name, "api_key", key)
              @provider_keys[name] = key
              agent.api_key = nil # 配置树抹除明文（setter）
              Log.info { "credential migrated to vault for agent #{name} (plaintext removed from config tree)" }
            else
              # 配置无明文（重建/重跑路径）：从 vault 恢复凭据映射——wrapped
              # factory 依赖 @provider_keys 注入，缺失会让 provider 拿到 nil
              restored = vault.get("agent", name, "api_key")
              @provider_keys[name] = restored if restored
            end
          end
        end
      end
    end
  end
end
