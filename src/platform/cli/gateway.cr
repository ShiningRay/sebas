require "json"
require "../../routing/binding"
require "../config/loader"
require "../config/reload"
require "../keys/vault"
require "../keys/win_credential_manager"
require "../supervisor/supervisor"
require "./gateway_secrets"
require "./gateway_telegram"
require "../../channels/email/adapter"
require "../../admin/http/server"
require "../bus/bus"
require "../store/store"
require "../../agents/pool"
require "../../agents/agents"
require "../../agents/reception/reception"
require "../../sessions/lifecycle/lifecycle"
require "../../sessions/compaction/compactor"
require "../../channels/registry"
require "../../providers/providers"
require "../../providers/pool"
require "../../providers/fake_provider"
require "../../providers/tool_call_parser"
require "../../sessions/scheduling/scheduler"
require "../../sessions/scheduling/registry"
require "../../sessions/scheduling/recovery"
require "../../sessions/scheduling/steer"
require "../../agents/runtime"
require "./gateway_dispatch"
require "./gateway_steer"
require "./gateway_hooks"
require "./gateway_reload"
require "./gateway_plugins"
require "./gateway_scheduling_admin"
require "./gateway_collaboration"
require "../../tools/executor"
require "../../orchestration/approvals/approvals"
require "../../orchestration/fork/fork_manager"
require "../../orchestration/fork/expectations"
require "../../tools/fork_tool"
require "../../orchestration/fork/executor"
require "../../orchestration/fork/capability"
require "../../orchestration/fork/join_writer"
require "../../orchestration/fork/snapshot_builder"
require "../../orchestration/engine"
require "../../orchestration/triggers/triggers"
require "../../orchestration/collaboration/collaboration"
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
        include GatewayDispatch
        include GatewayTelegram
        include GatewaySteer
        include GatewayHooks
        include GatewaySchedulingAdmin
        include GatewaySecrets
        include GatewayCollaboration
        include GatewayReload
        include GatewayPlugins

        Log = Sebas::Log.for("gateway")

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
        getter steer_registry : Sessions::Scheduling::TurnRegistry
        getter engine : Orchestration::Engine
        getter triggers : Orchestration::TriggerManager
        @steer_dispatch_ready = Atomic(Bool).new(false) # 恢复重放完成后才允许派发（QWvO）
        getter steer_center : Sessions::Scheduling::SteerCenter
        # 协作 messenger（#185 WP1）：装配失败保持 nil——message_agent 不入工具面
        @collaboration_messenger : ::Sebas::Orchestration::Collaboration::Messenger? = nil

        # 池内批次执行体（run_batch_job）：装配完成后回填——断开 initialize 静态图里
        # pool handler ↔ scheduling registry 的循环引用
        @batch_job_handler : Proc(Agents::Job, Nil)? = nil
        @stopping_scan = Atomic(Bool).new(false)

        def initialize(@config : Config::Config, data_dir : String | Path, config_path : String = "",
                       &original_factory : Config::AgentConfig, String? -> Providers::Provider)
          @config_path = config_path
          @data_dir = Path[data_dir]
          @store = Store::Store.new(@data_dir / "sebas.db")
          @lifecycle_store = Sessions::Lifecycle::Store.new(@store, @data_dir)
          @vault = Keys::EncryptedFileVault.open(@data_dir / "secrets.vault", platform_keyring)
          migrate_secrets(@config) # secrets 收敛（M4.2-WP4 §5.3，包装见 GatewaySecrets）
          @provider_factory = wire_secret_factory(original_factory)
          @bus = Bus::Bus.new
          @channels = Channels::Registry.new
          @providers = Providers::Pool.new
          @tools_registry = Tools.default_registry(@channels)
          @executor = Tools::Executor.new(@tools_registry, @channels)
          wire_plugins(@config)            # 插件面装配（M3-WP4）：先于 pool/agent 工具面构建
          wire_hook_faces; wire_compaction # hook 门面+归档压缩接线（M3-WP5 #17）
          @rules = build_rules(config)
          @pool = build_pool
          @scheduling = Sessions::Scheduling::Registry.new(@store)
          scheduling.dispatch_handler = ->(session_key : String, payload : String) { @pool.enqueue(session_key, payload) }
          @batch_job_handler = ->(job : Agents::Job) { run_batch_job(job) }
          # debounce seal 扫描定时器（#5 WP3）
          spawn(name: "sebas-schedule-seal-scanner") do
            loop do
              sleep 100.milliseconds
              break if @stopping_scan.get
              begin
                @scheduling.seal_due
              rescue ex
                # 单次扫描异常（瞬时 SQLite 故障等）不停摆扫描协程：
                # idle/max_wait 桶仍需后续 tick 收口（CodeRabbit）
                Log.error(exception: ex) { "seal scan failed, next tick continues" }
              end
            end
          end
          # busy steer 中心（M4.5-WP4）：100ms 协程粒度（同 seal 扫描）
          @steer_registry = Sessions::Scheduling::TurnRegistry.new
          @steer_center = Sessions::Scheduling::SteerCenter.new(@store, @steer_registry,
            ->(session : String) { steering_policy(session) })
          spawn_steer_scanners # 过期扫描 + outbox 派发（M4.5-WP6 抽出）
          Config::CURRENT.set(config)
          @supervisor = Supervisor::Supervisor.new(@bus)
          @reload_manager = Config::ReloadManager.new(config_path) { |config| apply_config(config) }
          # Approvals::Center 生产装配（M4.2-WP3）：先于 IPC 构造——IPC
          # approvals.approve/deny/pending 命令直接引用；规则链（hardline >
          # off > 无人值守 deny > memo > 超时 deny > 等待人工）现成。
          @approvals = Orchestration::Approvals::Center.new(@store)
          # IPC host 固定回环（#153 复审）：不继承 http.bind——bind: 0.0.0.0
          # 会撞 IPC 回环白名单令 gateway 启动失败；IPC 明文 TCP 只应本机可达。
          @ipc = Admin::IPC::Server.new(@store, @data_dir,
            host: "127.0.0.1",
            port: @config.gateway.ipc.port,
            &->trigger_reload)
          @ipc.approvals_center = @approvals
          @ipc.fork_handler = ->(payload : JSON::Any) { handle_fork_command(payload) }
          wire_steer_handler
          http_cfg = @config.gateway.http
          @http = Admin::HTTP::Server.new(@channels, @ipc.tap,
            http_cfg.try(&.bind) || "127.0.0.1", http_cfg.try(&.port) || 18790,
            http_cfg.try(&.auth) || "token", ENV["SEBAS_HTTP_TOKEN"]?,
            lifecycle: @lifecycle_store,
            &->trigger_reload)
          @store.recover!
          Sessions::Scheduling::Recovery.recover_stale(@store)
          @steer_center.recover_unconfirmed
          @agent_registry = Agents::AgentRegistry.new(@data_dir / "agents")
          # agent 间消息装配（#185 WP1）：registry/store 就绪后接线，工具面由
          # GatewayDispatch#attenuated_registry 按 agent.tools.allow 裁剪
          @collaboration_messenger = build_collaboration_messenger
          fork_factory = -> do # workflow 触发子系统（M4.5-WP5/WP6，装载在 hooks）
 cfg = Config::CURRENT.get.agents["main"]?
          raise Store::StoreError.new("engine fork factory: no main agent") unless cfg
          @provider_factory.call(cfg, nil)           end
          @engine = Orchestration::Engine.new(@store, @executor, "engine", nil, fork_factory)
          @engine.hook_bus = @hook_bus # task 域 hook 注入（M3-WP5，#17）
          @triggers = Orchestration::TriggerManager.new(@engine, @bus)
          load_workflows(@engine)
          @ipc.lifecycle_store = @lifecycle_store # 管理面注入（M4.4-WP4）
          @ipc.template_registry = @agent_registry
          @http.lifecycle = @lifecycle_store
          @http.templates = @agent_registry
          @http.steer_center = @steer_center
          wire_hook_handler; wire_scheduling_admin
          @fork_manager = Orchestration::Fork::ForkManager.new(@store, @agent_registry, @providers, @approvals)
          @join_writer = Orchestration::Fork::JoinWriter.new(@store) # fork/join 装配
          spawn_adapters
        end

        def run : Nil
          @ipc.listen
          @http.listen
          @supervisor.start_all
          replay_unfinished               # 崩溃恢复重放先于调度启动（同会话不出现双 turn）
          @engine.resume_interrupted      # 中断 workflow run 续跑（aD57；需 workflows 注册表已载）
          scheduling.recover_dispatch     # 持久待发批次重派（§5.2：sealed/queued 重新入队）
          confirm_telegram_after_recovery # M3-WP8：replay 后统一补确认 telegram dispatched（窗口 C）
          @steer_dispatch_ready.set(true) # 恢复完成后启用 queued steer 派发（QWvO）
          fire_gateway_start              # gateway.start hook（M3-WP5，#17）
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

        def shutdown : Nil
          fire_gateway_stop; @stopping_scan.set(true) # gateway.stop hook（M3-WP5 #17）+ 扫描协程先退（CodeRabbit）
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
          # message.received（M3-WP5，#17 §12.11）：渠道验真/去重/解析完成后、
          # 路由前 observe（只读，失败不阻断接收——HookBus 内部隔离）
          observe_message_received(message) # message.received hook（M3-WP5 #17）
          # 重放（崩溃恢复）跳过 intent 排重：已存在 intent 继续 dispatch（send 幂等键防重复投递）
          intent_new = replay || @store.record_intent(message.event_id, "message", message.to_json)
          confirm_telegram_consumer(message) # M3-WP8 §4.2：消费者确认（含已有 intent 分支，防永卡 dispatched=false）
          return unless intent_new
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
          # 归档会话写拒绝（M4.4-WP3：归档可查不可写）
          if @lifecycle_store.archived?(session_key)
            Log.warn { "audit: write rejected for archived session #{session_key} (event=#{message.event_id})" }
            @store.finish_intent(message.event_id, "failed")
            return
          end
          return if handle_steer_command(message, session_key)
          @store.append_transcript(session_key, "user", message.content)

          task = @store.create_task("turn:#{message.event_id}", "turn", payload: message.to_json)
          reply = agent_turn(agent_name, agent, session_key, task_id: task.id, event_id: message.event_id)

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

        MAX_TOOL_ROUNDS = 8

        # ReAct 工具循环（M4.3-WP1）+ busy steer（M4.5-WP4）：循环本体在
        # AgentRuntime（provider/tool 循环 + TurnContext）；本方法只负责
        # 依赖组装与 turn 生命周期——注册 lease（generation 权威发放）→
        # runtime.run（drain 回调注 steer）→ finally 注销 + 未注入 pending
        # 转 queued 后续批次（验收：turn 结束不丢消息）。
        private def agent_turn(agent_name : String, agent : Config::AgentConfig,
                               session_key : String, task_id : String? = nil,
                               event_id : String = "", collab_hops : Int64? = nil) : String
          # 每 turn 取配置快照纪律（§11.2④）：M0 单配置整根即快照；M1 起 Atomic(Config).get
          history = @store.transcripts(session_key).last(agent.memory.try(&.window) || 50).map do |row|
            # agent → assistant；tool 行转 user（内容自带 "tool:" 前缀）——
            # HttpProvider 只序列化 role/content，tool 角色无 tool_call_id
            # 支撑会破坏后续对话（CodeRabbit Cv3j）
            role = case row.role
                   when "agent" then "assistant"
                   when "tool"  then "user"
                   else              row.role
                   end
            Providers::Message.new(role, row.content)
          end
          registry = attenuated_registry(agent)
          register_dialog_fork_tool(registry, agent_name, agent)
          front_desk = agent_name == ::Sebas::Agents::Reception::FRONT_DESK_AGENT
          restrict_registry_to_read_only(registry) if front_desk
          # 每 turn 共享 Budget（M3-WP5 review，§12.11 预算按 turn 划界）：
          # agent/llm、tool、message 三域 hook 派发绑定同一预算实例，turn 级
          # 累计上限生效；turn 结束随局部变量丢弃
          turn_budget = ::Sebas::Plugins::HookDispatcher::Budget.new
          hook_bus = ::Sebas::Plugins::HookBus.new(@hook_bus.dispatcher,
            budget_factory: -> { turn_budget })
          if send_tool = registry.find("message.send").as?(Tools::MessageSendTool)
            send_tool.hook_bus = hook_bus # 消息域注入（per-turn 实例，M3-WP5 #17）
          end
          executor = Tools::Executor.new(registry, @channels, hook_bus) # 工具域注入（M3-WP5 #17）
          provider = @providers.for_agent(agent_name) { @provider_factory.call(agent, nil) }

          # 工具协议说明（M4.3-WP1 CodeRabbit）：模型必须知道可用工具与调用
          # 协议才能发起调用——首条 system 消息注入清单（registry.describe）
          # 与 fenced JSON 调用格式示例；前台会话追加转介建议（M4.3-WP3）。
          system_text = tool_protocol_prompt(registry)
          system_text += "\n\n" + ::Sebas::Agents::Reception.referral_prompt if front_desk
          messages = [Providers::Message.new("system", system_text)] + history

          # steer drain 回调（M4.5-WP4）：固定顺序「工具结果落库 → drain →
          # 下一次模型调用」的轮边界唯一注入点
          drain = ->(session : String, turn_id : String, generation : Int64) do
            @steer_center.drain(session, turn_id, generation)
          end
          runtime = Agents::AgentRuntime.new(@store, @approvals, drain)
          inject_runtime_hooks(runtime, hook_bus) # agent/llm 域 hook（M3-WP5 #17，turn 级 Budget）
          turn_id = "turn:#{event_id}"
          lease = @steer_registry.register(session_key, turn_id)
          turn_ctx = Agents::TurnContext.new(session_key, lease.turn_id, lease.generation)
          begin
            runtime.run(session_key, turn_ctx, provider, executor, messages, task_id, event_id, collab_hops)
          ensure
            @steer_registry.unregister(session_key, turn_id)
            begin
              @steer_center.flush_to_queue(session_key, turn_id) # queued outbox，扫描器接管派发
            rescue ex
              Log.error(exception: ex) { "steer flush failed (turn=#{turn_id})" }
            end
          end
        end

        private def build_pool : Agents::Pool
          Agents::Pool.new(8, 16) do |job|
            handler = @batch_job_handler
            handler.call(job) unless handler.nil? # 装配完成前无 job 进入（dispatch 未接线）
          end
        end
      end
    end
  end
end
