require "json"
require "../config/reload"

# 配置热更新触发面（#163 拆分口径：gateway.cr 行数回归闸内）：reload 命令
# 响应载荷与触发 + 组件重应用矩阵 apply_config（#287 review 移入——reload
# 语义同族，含 degraded 降级通道）。IPC/HTTP 的 reload 入口经
# `&->trigger_reload` 引用本方法。
module Sebas
  module Platform
    module CLI
      module GatewayReload
        def reload_result_payload(result : Config::ReloadResult) : Hash(String, JSON::Any)
          {
            "accepted"         => JSON::Any.new(result.accepted),
            "errors"           => JSON::Any.new(result.errors.map { |e| JSON::Any.new(e) }),
            "restart_required" => JSON::Any.new(result.restart_required.map { |e| JSON::Any.new(e) }),
            "degraded"         => JSON::Any.new(result.degraded.map { |e| JSON::Any.new(e) }),
          }
        end

        def trigger_reload : Hash(String, JSON::Any)
          manager = @reload_manager
          return {"accepted" => JSON::Any.new(false), "errors" => JSON::Any.new([JSON::Any.new("no config path; reload unavailable")]), "restart_required" => JSON::Any.new([] of JSON::Any), "degraded" => JSON::Any.new([] of JSON::Any)} if manager.nil?
          result = manager.reload_from_file
          reload_result_payload(result)
        end

        # 组件重应用矩阵（§11.3）：数据类热换；账号增删=监督体启停；端口类标 restart
        private def apply_config(new_config : Config::Config) : Config::ApplyOutcome
          restart_required = [] of String
          degraded = [] of String

          old_http = @config.gateway.http
          new_http = new_config.gateway.http
          if old_http && new_http && (old_http.port != new_http.port || old_http.bind != new_http.bind)
            restart_required << "gateway.http.port/bind changed: sockets are process resources, restart required"
          end

          # 路由 binding（数据类：换引用即生效）
          @rules = build_rules(new_config)

          # provider key 热换（下个 turn 生效）；热更新带入的明文同样收敛
          migrate_secrets(new_config)
          new_config.agents.each do |name, agent|
            @providers.replace(name, @provider_factory.call(agent, nil))
          end
          # 协作防环上限（数据类热换，#185）：在途链路不变，下条投递按新值判
          @collaboration_messenger.try(&.max_hops = new_config.gateway.collaboration.max_hops)

          # 账号增删 = 监督体启停（email 渠道；wecom/lark M1-WP4/5 合流）
          old_accounts = @config.channels.email.try(&.accounts.map(&.id)) || [] of String
          new_accounts = new_config.channels.email.try(&.accounts.map(&.id)) || [] of String
          (old_accounts - new_accounts).each do |removed|
            @channels.remove("email", removed)
            @supervisor.remove_account(removed)
          end
          (new_accounts - old_accounts).each do |added|
            account = new_config.channels.email.try(&.accounts.find(&.id.==(added)))
            next unless account
            adapter = Channels::Email::EmailChannelAdapter.new(account, @bus)
            @channels.register(adapter)
            @supervisor.register(adapter)
          end

          # Telegram 账号热换（M3-WP8 装配）：增删=监督体启停
          reapply_telegram_accounts(new_config)

          # 插件面热更新（M3-WP4），hook 门面与压缩运行器同步刷新（M3-WP5
          # review：CompactionRunner 按值持有 HookBus struct，不重建则
          # session.compact.* 仍绑定启动代总线）；hook 门面刷新含 task 域
          # （M3-WP5 #17）；装配失败记降级（不与 restart_required 混用）
          unless wire_plugins(new_config)
            degraded << "plugins face wiring failed: hooks and plugin tools disabled"
          end
          wire_hook_faces; wire_compaction; @engine.hook_bus = @hook_bus
          @config = new_config
          Config::ApplyOutcome.new(restart_required, degraded)
        end
      end
    end
  end
end
