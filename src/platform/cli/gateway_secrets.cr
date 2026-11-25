# Gateway secrets 收敛（M4.2-WP4，#49，自 gateway.cr 拆分）：
# 配置明文 api_key 迁 vault（幂等）+ 配置树抹除 + provider 解析键记录。
# 本 module 由 Gateway include，方法直接访问宿主实例变量——拆分只改代码
# 组织，不改行为（同 gateway_dispatch.cr 模式）。
#
# #214 扩展：provider 层（providers.<name>）密钥迁 vault 走 ("provider", name)
# 命名空间；wrapped factory 密钥决议 provider 级 > agent 级（遗留过渡），
# 同一 provider 的全部引用 agent 共享一份密钥，热更新轮换下个 turn 生效。
require "../config/reload" # default_provider 读 Config::CURRENT（显式声明依赖）

module Sebas
  module Platform
    module CLI
      # 生产 provider 装配（#214，模块级——原 Gateway.default_provider 迁入）：
      # 决议（Providers.resolve 纯函数）→ HttpProvider。provider 级配置
      # （base_url/protocol）读 Config::CURRENT 快照——initialize 与 reload
      # 都先 set 再 apply，工厂调用时序上新配置必已就位；密钥不在此处解析
      # （GatewaySecrets 包装工厂经 key 参数注入，provider 级 > agent 级遗留）。
      module GatewaySecrets
        def self.default_provider(agent : Config::AgentConfig, api_key : String?) : Providers::Provider
          name = agent.provider || agent.provider_ref || agent.model.split("/").first?
          name = name.try { |candidate| candidate.strip.empty? ? nil : candidate.strip }
          pcfg = name.try { |provider_name| Config::CURRENT.get.providers[provider_name]? }
          cfg = pcfg.try { |entry| Providers::ProviderCfg.new(entry.api_key, entry.base_url, entry.protocol) }
          spec = name.try { |provider_name| Providers.spec_for(provider_name) }
          resolution = Providers.resolve(agent.provider, agent.provider_ref, agent.model, cfg, spec, nil, api_key)
          key = resolution.api_key
          if key.nil? || key.strip.empty?
            raise ::Exception.new(
              "no api_key resolved for provider '#{resolution.name}': set providers.#{resolution.name}.api_key or legacy agents.<name>.api_key")
          end
          Providers::HttpProvider.new(
            Providers::Spec.new(resolution.name, resolution.base_url, resolution.format),
            resolution.model, key)
        end

        # secrets vault（M4.2-WP4）：AES-256-GCM 静态加密（主密钥 OS keyring，
        # 降级 0600 主密钥文件）；分身执行面无凭据直读路径（provider 句柄封装）。
        getter vault : Keys::EncryptedFileVault
        getter lifecycle_store : Sessions::Lifecycle::Store
        @provider_factory : Proc(Config::AgentConfig, String?, Providers::Provider)
        # agent 名 → vault 解析 key（遗留 agent 级 api_key 过渡通道，#214）
        @agent_keys : Hash(String, String) = Hash(String, String).new
        # provider 名 → vault 解析 key（#214：provider 级密钥，多 agent 共享）
        @provider_secrets : Hash(String, String) = Hash(String, String).new
        # agent 名 → 最新实例（migrate_secrets 维护）：wrapped factory 按实例
        # 身份反查名字，注入 vault 解析 key（热更新换 @config 引用不依赖）。
        @agent_instances : Hash(String, Config::AgentConfig) = Hash(String, Config::AgentConfig).new

        # 工厂包装：先按 provider 级密钥决议（provider > agent 遗留），注入
        # vault 解析 key（热更新换 @config 引用不依赖 @agent_instances 之外的状态）。
        def wire_secret_factory(original_factory : Proc(Config::AgentConfig, String?, Providers::Provider)) : Proc(Config::AgentConfig, String?, Providers::Provider)
          ->(agent : Config::AgentConfig, key : String?) {
            original_factory.call(agent, resolve_secret(agent) || key)
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

        # provider 名判定（与 Providers.resolve 同序）：显式 provider >
        # provider_ref（兼容）> model 前缀推断（遗留）
        private def provider_name_for(agent : Config::AgentConfig) : String?
          name = agent.provider || agent.provider_ref || agent.model.split("/").first?
          name.try { |candidate| candidate.strip.empty? ? nil : candidate.strip }
        end

        # 密钥决议（#214）：provider 级 > agent 级（遗留过渡）> nil（回退
        # original_factory 的 key 参数）。
        private def resolve_secret(agent : Config::AgentConfig) : String?
          if name = provider_name_for(agent)
            secret = @provider_secrets[name]?
            return secret if secret
          end
          agent_name = @agent_instances.find { |_, candidate| candidate.same?(agent) }.try(&.[0])
          agent_name.try { |registered| @agent_keys[registered]? }
        end

        # 明文凭据迁移（M4.2-WP4 §5.3，幂等可重跑；#214 扩展 provider 层）：
        # 配置树 api_key 非空 → 写 vault（覆盖写幂等）+ 内存抹除（setter 置 nil）
        # + 记录解析键。热更新路径（apply_config）同样走此收敛——provider 级
        # 密钥轮换在此刷新 @provider_secrets，随后 apply_config 重建全部引用
        # agent 的 provider 实例（下个 turn 生效）。
        def migrate_secrets(config : Config::Config) : Nil
          config.providers.each do |name, pcfg|
            key = pcfg.api_key
            if key
              vault.set("provider", name, "api_key", key)
              @provider_secrets[name] = key
              pcfg.api_key = nil # 配置树抹除明文（setter）
              Log.info { "credential migrated to vault for provider #{name} (plaintext removed from config tree)" }
            else
              # 配置无明文（重建/重跑路径）：从 vault 恢复凭据映射
              restored = vault.get("provider", name, "api_key")
              @provider_secrets[name] = restored if restored
            end
          end
          config.agents.each do |name, agent|
            @agent_instances[name] = agent
            key = agent.api_key
            if key
              vault.set("agent", name, "api_key", key)
              @agent_keys[name] = key
              agent.api_key = nil # 配置树抹除明文（setter）
              Log.info { "credential migrated to vault for agent #{name} (plaintext removed from config tree)" }
            else
              # 配置无明文（重建/重跑路径）：从 vault 恢复凭据映射——wrapped
              # factory 依赖 @agent_keys 注入，缺失会让 provider 拿到 nil
              restored = vault.get("agent", name, "api_key")
              @agent_keys[name] = restored if restored
            end
          end
        end
      end
    end
  end
end
