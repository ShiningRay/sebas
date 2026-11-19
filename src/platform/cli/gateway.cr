require "json"
require "../../routing/binding"
require "../config/loader"
require "../config/reload"
require "../supervisor/supervisor"
require "../../channels/email/adapter"
require "../../admin/http/server"
require "../bus/bus"
require "../store/store"
require "../../agents/pool"
require "../../channels/registry"
require "../../providers/providers"
require "../../providers/pool"
require "../../providers/fake_provider"
require "../../tools/executor"
require "../../admin/ipc/server"
require "../../log"

# Gateway（M0-WP8 装配）：单常驻进程组装全链路——
# config → store(recover!) → bus → 渠道适配器 → agent 池 → 工具执行器 → IPC 管理面。
# 消息处理 = 效应三明治：intent 落库 → task+checkpoint → provider turn → 发信（幂等键）→ 落库。
module Sebas
  module Platform
    module CLI
      class Gateway
        Log = Sebas::Log.for("sebas.gateway")

        getter config : Config::Config
        getter store : Store::Store
        getter bus : Bus::Bus
        getter pool : Agents::Pool
        getter channels : Channels::Registry
        getter providers : Providers::Pool
        getter ipc : Admin::IPC::Server
        getter rules : Array(Routing::BindingRule)
        getter supervisor : Supervisor::Supervisor
        getter reload_manager : Config::ReloadManager?
        getter http : Admin::HTTP::Server

        def initialize(@config : Config::Config, data_dir : String | Path, config_path : String = "",
                       &@provider_factory : Config::AgentConfig, String? -> Providers::Provider)
          @config_path = config_path
          @data_dir = Path[data_dir]
          @store = Store::Store.new(@data_dir / "sebas.db")
          @bus = Bus::Bus.new
          @channels = Channels::Registry.new
          @providers = Providers::Pool.new
          @executor = Tools::Executor.new(Tools.default_registry(@channels), @channels)
          @rules = build_rules(config)
          @pool = build_pool
          Config::CURRENT.set(config)
          @supervisor = Supervisor::Supervisor.new(@bus)
          @reload_manager = Config::ReloadManager.new(config_path) { |config| apply_config(config) }
          @ipc = Admin::IPC::Server.new(@store, @data_dir,
            host: @config.gateway.http.try(&.bind) || "127.0.0.1",
            port: @config.gateway.ipc.port,
            &->trigger_reload)
          http_cfg = @config.gateway.http
          @http = Admin::HTTP::Server.new(@channels, @ipc.tap,
            http_cfg.try(&.bind) || "127.0.0.1", http_cfg.try(&.port) || 18790,
            http_cfg.try(&.auth) || "token", ENV["SEBAS_HTTP_TOKEN"]?,
            &->trigger_reload)
          @store.recover!
          spawn_adapters
        end

        def reload_result_payload(result : Config::ReloadResult) : Hash(String, JSON::Any)
          {
            "accepted"         => JSON::Any.new(result.accepted),
            "errors"           => JSON::Any.new(result.errors.map { |e| JSON::Any.new(e) }),
            "restart_required" => JSON::Any.new(result.restart_required.map { |e| JSON::Any.new(e) }),
          }
        end

        def trigger_reload : Hash(String, JSON::Any)
          manager = @reload_manager
          return {"accepted" => JSON::Any.new(false), "errors" => JSON::Any.new([JSON::Any.new("no config path; reload unavailable")]), "restart_required" => JSON::Any.new([] of JSON::Any)} if manager.nil?
          result = manager.reload_from_file
          reload_result_payload(result)
        end

        def self.default_provider(agent : Config::AgentConfig, api_key : String?) : Providers::Provider
          api_key = agent.api_key || api_key
          provider_ref = agent.provider_ref || agent.model.split("/").first?
          spec = Providers.spec_for(provider_ref || "")
          raise ::Exception.new("unknown provider '#{provider_ref}' for model '#{agent.model}'") unless spec
          Providers::HttpProvider.new(spec, agent.model.split("/", limit: 2)[1]? || agent.model, api_key || "")
        end

        def run : Nil
          @ipc.listen
          @http.listen
          @supervisor.start_all
          consume_bus
          if @config_path.empty?
            Log.info { "gateway running (data_dir=#{@data_dir}; config reload disabled: no config path)" }
          else
            manager = @reload_manager
            return unless manager
            manager.start_watching
            Log.info { "gateway running (data_dir=#{@data_dir})" }
          end
        end

        # 组件重应用矩阵（§11.3）：数据类热换；账号增删=监督体启停；端口类标 restart
        private def apply_config(new_config : Config::Config) : Array(String)
          restart_required = [] of String

          old_http = @config.gateway.http
          new_http = new_config.gateway.http
          if old_http && new_http && (old_http.port != new_http.port || old_http.bind != new_http.bind)
            restart_required << "gateway.http.port/bind changed: sockets are process resources, restart required"
          end

          # 路由 binding（数据类：换引用即生效）
          @rules = build_rules(new_config)

          # provider key 热换（下个 turn 生效）
          new_config.agents.each do |name, agent|
            @providers.replace(name, @provider_factory.call(agent, nil))
          end

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

          @config = new_config
          restart_required
        end

        def shutdown : Nil
          @reload_manager.try(&.stop_watching)
          @http.close
          @supervisor.stop_all
          @pool.shutdown
          @bus.close
          @ipc.close
          @store.close
        end

        # 处理一条入站消息（效应三明治 + 幂等三件套；spec 可直接调用）
        def process_message(message : Bus::InboundMessage, replay : Bool = false) : Nil
          # 重放（崩溃恢复）跳过 intent 排重：已存在 intent 继续 dispatch（send 幂等键防重复投递）
          return unless replay || @store.record_intent(message.event_id, "message", message.to_json)
          @store.finish_intent(message.event_id, "dispatched")

          # Binding 路由（M1-WP1）：most-specific 解析；无匹配 fail-closed 丢弃+审计
          agent_name = Routing::Table.resolve(@rules, message.channel_type, message.account_id, message.peer)
          unless agent_name
            Log.warn { "audit: inbound dropped without matching binding (channel=#{message.channel_type} account=#{message.account_id} peer=#{message.peer} event=#{message.event_id})" }
            @store.finish_intent(message.event_id, "failed")
            return
          end
          agent = Config::CURRENT.get.agents[agent_name]?
          unless agent
            Log.error { "audit: binding targets unknown agent #{agent_name}" }
            @store.finish_intent(message.event_id, "failed")
            return
          end
          session_key = Agents.session_key(agent_name, message.account_id, message.channel_type, message.peer)
          @store.append_transcript(session_key, "user", message.content)

          task = @store.create_task("turn:#{message.event_id}", "turn", payload: message.to_json)
          reply = agent_turn(agent_name, agent, session_key)
          @store.checkpoint(task.id, 1) # provider 完成 checkpoint（重放不再调 provider）

          send_args = JSON.parse({channel: message.channel_type, peer: message.peer, content: reply}.to_json)
          send_result = @executor.run("message.send", send_args,
            Tools::ToolContext.new(session_key, message.account_id, message.event_id, @store))

          if send_result.ok?
            @store.append_transcript(session_key, "agent", reply)
            @store.complete_task(task.id, reply)
            @store.finish_intent(message.event_id, "done")
          else
            @store.fail_task(task.id, send_result.error)
            # intent 保持 dispatched：重启重放时 send 幂等键防重复投递
          end
        rescue ex : ::Exception
          Log.error(exception: ex) { "message processing failed (event=#{message.event_id})" }
        end

        # 重放未完成 intents（崩溃恢复入口，M0-WP8 演练）
        def replay_unfinished : Nil
          @store.unfinished_intents.each do |intent|
            next unless intent.kind == "message"
            begin
              data = JSON.parse(intent.payload)
              message = Bus::InboundMessage.new(
                data["event_id"].as_s, data["channel_type"].as_s,
                data["account_id"].as_s, data["peer"].as_s, data["content"].as_s
              )
              Log.info { "replaying unfinished intent #{intent.id} (#{intent.status})" }
              process_message(message, replay: true)
            rescue ex : ::Exception
              Log.error(exception: ex) { "intent replay failed (#{intent.id})" }
            end
          end
        end

        private def agent_turn(agent_name : String, agent : Config::AgentConfig, session_key : String) : String
          # 每 turn 取配置快照纪律（§11.2④）：M0 单配置整根即快照；M1 起 Atomic(Config).get
          history = @store.transcripts(session_key).last(agent.memory.try(&.window) || 50).map do |row|
            role = row.role == "agent" ? "assistant" : row.role
            Providers::Message.new(role, row.content)
          end
          provider = @providers.for_agent(agent_name) { @provider_factory.call(agent, nil) }
          completion = provider.complete(history)
          return completion.text if completion.ok?
          Log.error { "provider error: #{completion.error}" }
          "(provider error: #{completion.error})"
        end

        private def spawn_adapters : Nil
          if email = @config.channels.email
            email.accounts.each do |account|
              adapter = Channels::Email::EmailChannelAdapter.new(account, @bus)
              @channels.register(adapter)
              @supervisor.register(adapter)
            end
          end
          # wecom/lark 渠道 M1-WP4/5 落位（§13 channels/）
        end

        private def build_rules(config : Config::Config) : Array(Routing::BindingRule)
          config.bindings.map do |b|
            Routing::BindingRule.new(b.channel, b.account || "*", b.peer || "*", b.agent)
          end
        end

        private def build_pool : Agents::Pool
          Agents::Pool.new(8, 16) do |job|
            # 池内执行：payload 为 InboundMessage JSON
            data = JSON.parse(job.payload)
            process_message(Bus::InboundMessage.new(
              data["event_id"].as_s, data["channel_type"].as_s,
              data["account_id"].as_s, data["peer"].as_s, data["content"].as_s
            ))
          end
        end

        private def consume_bus : Nil
          spawn(name: "sebas-bus-consumer") do
            loop do
              event = @bus.receive?
              break if event.nil?
              case event
              when Bus::InboundMessage
                session_key = Agents.session_key("main", event.account_id, event.channel_type, event.peer)
                @pool.enqueue(session_key, event.to_json)
              when Bus::AccountEvent
                @ipc.tap.publish(Admin::IPC.event_line("account.#{event.kind}", {
                  "account_id" => JSON::Any.new(event.account_id),
                }))
              end
            end
          end
          Log.info { "bus consumer started" }
        end
      end
    end
  end
end
