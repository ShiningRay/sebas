require "json"
require "../config/loader"
require "../bus/bus"
require "../store/store"
require "../../agents/pool"
require "../../channels/registry"
require "../../channels/email/adapter"
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

        def initialize(@config : Config::Config, data_dir : String | Path,
                       &@provider_factory : Config::AgentConfig, String? -> Providers::Provider)
          @data_dir = Path[data_dir]
          @store = Store::Store.new(@data_dir / "sebas.db")
          @bus = Bus::Bus.new
          @channels = Channels::Registry.new
          @providers = Providers::Pool.new
          @executor = Tools::Executor.new(Tools.default_registry(@channels), @channels)
          @pool = build_pool
          @ipc = Admin::IPC::Server.new(@store, @data_dir,
            host: @config.gateway.http.try(&.bind) || "127.0.0.1",
            port: @config.gateway.ipc.port)
          @store.recover!
          spawn_adapters
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
          @channels.start_all
          consume_bus
          Log.info { "gateway running (data_dir=#{@data_dir})" }
        end

        def shutdown : Nil
          @channels.stop_all
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

          agent_name, agent = first_agent
          session_key = Agents.session_key(agent_name, message.account_id, message.channel_type, message.peer)
          @store.append_transcript(session_key, "user", message.content)

          task = @store.create_task("turn:#{message.event_id}", "turn", payload: message.to_json)
          reply = agent_turn(agent, session_key)
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

        private def agent_turn(agent : Config::AgentConfig, session_key : String) : String
          # 每 turn 取配置快照纪律（§11.2④）：M0 单配置整根即快照；M1 起 Atomic(Config).get
          history = @store.transcripts(session_key).last(agent.memory.try(&.window) || 50).map do |row|
            role = row.role == "agent" ? "assistant" : row.role
            Providers::Message.new(role, row.content)
          end
          provider = @providers.for_agent("main") { @provider_factory.call(agent, nil) }
          completion = provider.complete(history)
          return completion.text if completion.ok?
          Log.error { "provider error: #{completion.error}" }
          "(provider error: #{completion.error})"
        end

        private def first_agent : Tuple(String, Config::AgentConfig)
          entry = @config.agents.first?
          raise ::Exception.new("no agent configured") unless entry
          entry
        end

        private def spawn_adapters : Nil
          if email = @config.channels.email
            email.accounts.each do |account|
              @channels.register(Channels::Email::EmailChannelAdapter.new(account, @bus))
            end
          end
          # wecom/lark 渠道 M1 落位（§13 channels/）
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
