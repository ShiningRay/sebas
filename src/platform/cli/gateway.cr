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
require "../../agents/agents"
require "../../channels/registry"
require "../../providers/providers"
require "../../providers/pool"
require "../../providers/fake_provider"
require "../../sessions/scheduling/scheduler"
require "../../sessions/scheduling/recovery"
require "../../tools/executor"
require "../../orchestration/approvals/approvals"
require "../../orchestration/fork/fork_manager"
require "../../orchestration/fork/join_writer"
require "../../admin/ipc/server"
require "../../log"

# Gateway（M0-WP8 装配）：单常驻进程组装全链路——
# config → store(recover!) → 调度恢复 → bus → 渠道适配器 → 调度权威 → agent 池 → 工具执行器 → IPC 管理面。
# 消息处理 = 效应三明治：intent 落库 → task+checkpoint → provider turn → 发信（幂等键）→ 落库。
# 调度链路（WP2）：Adapter → Router（admission 前解析）→ Scheduler.admit（SQLite 事务成功才接受）
# → queue seal → SessionWorker dispatch → 完成回调收敛批次（session-input-scheduling.md §7）。
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
        getter scheduling : Sessions::Scheduling::Registry
        # orchestration/agents 装配面（M4.1-WP1，Q4：全线前置首包）。
        getter agent_registry : ::Sebas::Agents::AgentRegistry
        getter approvals : ::Sebas::Orchestration::Approvals::Center
        getter fork_manager : ::Sebas::Orchestration::Fork::ForkManager
        getter join_writer : ::Sebas::Orchestration::Fork::JoinWriter

        # 池内批次执行体（run_batch_job）：装配完成后回填——断开 initialize 静态图里
        # pool handler ↔ scheduling registry 的循环引用
        @batch_job_handler : Proc(Agents::Job, Nil)? = nil

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
          @scheduling = Sessions::Scheduling::Registry.new(@store)
          scheduling.dispatch_handler = ->(session_key : String, payload : String) { @pool.enqueue(session_key, payload) }
          @batch_job_handler = ->(job : Agents::Job) { run_batch_job(job) }
          Config::CURRENT.set(config)
          @supervisor = Supervisor::Supervisor.new(@bus)
          @reload_manager = Config::ReloadManager.new(config_path) { |config| apply_config(config) }
          @ipc = Admin::IPC::Server.new(@store, @data_dir,
            host: @config.gateway.http.try(&.bind) || "127.0.0.1",
            port: @config.gateway.ipc.port,
            &->trigger_reload)
          # fork/join 用户显式触发面接线（M4.1-WP5，Q3：不动生产 agent_turn）：
          # IPC payload → Executor 执行 → 结果 JSON（回执 + expectation 终态）。
          @ipc.fork_handler = ->(payload : JSON::Any) { handle_fork_command(payload) }
          http_cfg = @config.gateway.http
          @http = Admin::HTTP::Server.new(@channels, @ipc.tap,
            http_cfg.try(&.bind) || "127.0.0.1", http_cfg.try(&.port) || 18790,
            http_cfg.try(&.auth) || "token", ENV["SEBAS_HTTP_TOKEN"]?,
            &->trigger_reload)
          @store.recover!
          Sessions::Scheduling::Recovery.recover_stale(@store)
          # orchestration 装配置 initialize 尾段（恢复完成后）：组件可达即装配成立；
          # fork 执行体（WP3）/ 回写本体（WP4）/ expectations 判定（WP2）后续包填充，
          # Approvals::Center 装配即通——M4.1 默认只读档无 L3 工具，不触发审批链。
          @agent_registry = Agents::AgentRegistry.new(@data_dir / "agents")
          @approvals = Orchestration::Approvals::Center.new(@store)
          @fork_manager = Orchestration::Fork::ForkManager.new(@store, @agent_registry, @providers, @approvals)
          @join_writer = Orchestration::Fork::JoinWriter.new(@store)
          spawn_adapters
        end

        # IPC fork 命令处理（M4.1-WP5）：payload 字段 task/count/mode/deadline/
        # window；路由到当前装配的 ForkManager/Executor，join 回写由 Expectations
        # + JoinWriter 在终态判定后落父会话（默认父会话 = 命令指定或 "agent:main:internal:main:fork-cli"）。
        def handle_fork_command(payload : JSON::Any) : JSON::Any # payload = frame.data 包裹为 JSON::Any.new(hash)
          data = payload.as_h? || {} of String => JSON::Any
          task = data["task"]?.try(&.as_s?) || ""
          raise ::Sebas::Platform::Store::StoreError.new("fork 命令缺 task") if task.empty?
          count = data["count"]?.try(&.as_i?) || 1
          mode = data["mode"]?.try(&.as_s?) || "allSettled"
          deadline = data["deadline"]?.try(&.as_i?) || 3600
          parent_session = data["parent_session"]?.try(&.as_s?) || "agent:main:internal:main:fork-cli"

          input = Orchestration::Fork::SnapshotBuilder::Input.new(
            task: task, count: count, window: data["window"]?.try(&.as_i?),
            include: nil, tools: nil, role: data["role"]?.try(&.as_s?),
            mode: mode, deadline: deadline
          )
          main_agent = @config.agents["main"]?
          raise ::Sebas::Platform::Store::StoreError.new("fork 命令缺 main agent 配置") if main_agent.nil?
          results = Orchestration::Fork::Executor.new(@store, Orchestration::Fork::Expectations.new(@store),
            -> { @providers.for_agent("main") { @provider_factory.call(main_agent, nil) } }).run(
            "cli-fork", parent_session, "main", "", "", input
          )
          JSON.parse({
            "fork_id" => results.first?.try(&.task_id.split(":")[0...2].join(":")).to_s,
            "members" => results.map { |result| {"task_id" => result.task_id, "state" => result.state}.to_json },
          }.to_json)
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
          replay_unfinished           # 崩溃恢复重放先于调度启动（同会话不出现双 turn）
          scheduling.recover_dispatch # 持久待发批次重派（§5.2：sealed/queued 重新入队）
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
          scheduling.shutdown # 停止派发；collecting 批保守封存（§5.2 shutdown 口径）
          @pool.shutdown
          @bus.close
          @ipc.close
          @store.close
        end

        # 处理一条入站消息（效应三明治 + 幂等三件套；spec 可直接调用）。
        # admitted_session：批次派发路径传入 admission 时确定的会话键——路由不再
        # 重解析（binding 热换不改在途批次归属），turn 在被调度的会话下执行。
        def process_message(message : Bus::InboundMessage, replay : Bool = false, admitted_session : String? = nil) : Nil
          # 重放（崩溃恢复）跳过 intent 排重：已存在 intent 继续 dispatch（send 幂等键防重复投递）
          return unless replay || @store.record_intent(message.event_id, "message", message.to_json)
          @store.finish_intent(message.event_id, "dispatched")

          if admitted_session
            # 调度派发路径：agent_id 取自五段键 agent 段（Agents.session_key 格式），
            # 会话与序列化归属即 admission 时的路由结果
            agent_name = admitted_session.split(":")[1]? || ""
            session_key = admitted_session
          else
            # Binding 路由（M1-WP1）：most-specific 解析；无匹配 fail-closed 丢弃+审计
            resolved = Routing::Table.resolve(@rules, message.channel_type, message.account_id, message.peer)
            unless resolved
              Log.warn { "audit: inbound dropped without matching binding (channel=#{message.channel_type} account=#{message.account_id} peer=#{message.peer} event=#{message.event_id})" }
              @store.finish_intent(message.event_id, "failed")
              return
            end
            agent_name = resolved
            session_key = Agents.session_key(agent_name, message.account_id, message.channel_type, message.peer)
          end
          agent = Config::CURRENT.get.agents[agent_name]?
          unless agent
            Log.error { "audit: binding targets unknown agent #{agent_name}" }
            @store.finish_intent(message.event_id, "failed")
            return
          end
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
            handler = @batch_job_handler
            handler.call(job) unless handler.nil? # 装配完成前无 job 进入（dispatch 未接线）
          end
        end

        # 池内执行：payload 为批次派发 JSON（{batch_id, session_key}）。成员 turn 逐条
        # 执行（queue 模式单成员），全部落库后按 intent 终态收敛批次并派发下一批。
        # 派发权威在 scheduler（每会话同时在途 ≤1），本方法只做执行与完成回调。
        # turn 在 admission 时确定的会话下执行（admitted_session 传入，不重解析路由）：
        # binding 热换不影响在途批次的会话归属，保序与序列化按 admitted session 成立。
        private def run_batch_job(job : Agents::Job) : Nil
          data = JSON.parse(job.payload)
          batch_id = data["batch_id"].as_s
          session_key = data["session_key"].as_s
          failed = [] of String
          if @store.session_batch(batch_id).nil?
            Log.error { "dispatch references missing batch #{batch_id} (session=#{session_key})" }
          else
            @store.batch_inputs(batch_id).each do |input|
              process_message(message_from_payload(input.payload), admitted_session: session_key)
              failed << input.event_id if @store.intent_status(input.event_id) != "done"
            end
          end
          scheduling.batch_done(session_key, batch_id, failed)
        rescue ex : JSON::ParseException
          Log.error(exception: ex) { "batch job payload unparsable (payload=#{job.payload[0, 120]})" }
        rescue ex : ::Exception
          # 执行体崩溃不炸 worker：批次 fail-closed 改判 failed（成员 intent 保持
          # dispatched，重启重放兜底），调度继续推进
          Log.error(exception: ex) { "batch job crashed (payload=#{job.payload[0, 120]})" }
          parsed = JSON.parse(job.payload)
          scheduling.batch_crashed(parsed["session_key"].as_s, parsed["batch_id"].as_s)
        end

        private def message_from_payload(payload : String) : Bus::InboundMessage
          data = JSON.parse(payload)
          Bus::InboundMessage.new(
            data["event_id"].as_s, data["channel_type"].as_s,
            data["account_id"].as_s, data["peer"].as_s, data["content"].as_s
          )
        end

        # admission 前置解析（契约 §4.2：Router 在 admission 前完成 agent/session 解析；
        # 无 binding 仍 fail-closed 丢弃并审计，不能先占队列）→ Scheduler.admit，
        # SQLite 事务成功才接受；重复投递幂等；容量超限拒绝并计数。
        private def schedule_input(event : Bus::InboundMessage) : Nil
          agent_name = Routing::Table.resolve(@rules, event.channel_type, event.account_id, event.peer)
          unless agent_name
            Log.warn { "audit: inbound dropped without matching binding (channel=#{event.channel_type} account=#{event.account_id} peer=#{event.peer} event=#{event.event_id})" }
            return
          end
          # admission 决策取 @config（apply_config 热换的权威快照）：agent 与
          # gateway.session 同源，避免 CURRENT 未随热更新时策略与 agent 定义分叉
          agent = @config.agents[agent_name]?
          unless agent
            Log.error { "audit: binding targets unknown agent #{agent_name} (event=#{event.event_id})" }
            return
          end
          session_key = Agents.session_key(agent_name, event.account_id, event.channel_type, event.peer)
          snapshot = Sessions::Scheduling::Policy.resolve_session(@config.gateway.session, agent.session)
          env = Sessions::Scheduling::InputEnvelope.new(
            event.event_id, session_key, event.channel_type, event.peer, 0,
            ::Time.utc.to_rfc3339, nil, event.to_json, snapshot
          )
          receipt = scheduling.admit(env)
          case receipt.status
          when "accepted"
            Log.info { "admitted (session=#{session_key} event=#{event.event_id} batch=#{receipt.batch_id} position=#{receipt.queue_position})" }
          when "duplicate"
            Log.debug { "duplicate admission (session=#{session_key} event=#{event.event_id})" }
          else
            Log.warn { "admission rejected (session=#{session_key} event=#{event.event_id})" }
          end
        end

        private def consume_bus : Nil
          spawn(name: "sebas-bus-consumer") do
            loop do
              event = @bus.receive?
              break if event.nil?
              case event
              when Bus::InboundMessage
                begin
                  schedule_input(event)
                rescue ex
                  # 单事件 admission 异常（瞬时 SQLite 故障等）不得停摆总线消费：
                  # fail-closed 丢弃并留错（契约 §6），后续事件继续处理
                  Log.error(exception: ex) { "admission failed, event dropped fail-closed (event=#{event.event_id})" }
                end
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
