require "json"
require "../../routing/binding"
require "../config/loader"
require "../config/reload"
require "../keys/vault"
require "../keys/win_credential_manager"
require "../supervisor/supervisor"
require "./gateway_secrets"
require "../../channels/email/adapter"
require "../../admin/http/server"
require "../bus/bus"
require "../store/store"
require "../../agents/pool"
require "../../agents/agents"
require "../../agents/reception/reception"
require "../../sessions/lifecycle/lifecycle"
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
require "../../tools/executor"
require "../../orchestration/approvals/approvals"
require "../../orchestration/fork/fork_manager"
require "../../orchestration/fork/expectations"
require "../../tools/fork_tool"
require "../../orchestration/fork/executor"
require "../../orchestration/fork/capability"
require "../../orchestration/fork/join_writer"
require "../../orchestration/fork/snapshot_builder"
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
        include GatewaySecrets

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
        getter steer_registry : Sessions::Scheduling::TurnRegistry
        getter steer_center : Sessions::Scheduling::SteerCenter

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
          # secrets 收敛（M4.2-WP4 §5.3）：配置明文 api_key 迁 vault（幂等），
          # 配置树抹除明文；provider 构造按 agent 名从 vault 取回（factory
          # 包装由 GatewaySecrets#wire_secret_factory 提供）。
          @vault = Keys::EncryptedFileVault.open(@data_dir / "secrets.vault", platform_keyring)
          migrate_secrets(@config)
          @provider_factory = wire_secret_factory(original_factory)
          @bus = Bus::Bus.new
          @channels = Channels::Registry.new
          @providers = Providers::Pool.new
          @executor = Tools::Executor.new(Tools.default_registry(@channels), @channels)
          @rules = build_rules(config)
          @pool = build_pool
          @scheduling = Sessions::Scheduling::Registry.new(@store)
          scheduling.dispatch_handler = ->(session_key : String, payload : String) { @pool.enqueue(session_key, payload) }
          @batch_job_handler = ->(job : Agents::Job) { run_batch_job(job) }
          # debounce seal 扫描定时器（#5 WP3）：100ms 粒度扫描全部会话的
          # collecting 桶（idle/max_wait 到期封冻入队）；进程内单调时钟。
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
          # busy steer 中心（M4.5-WP4）：turn 注册表 + 持久化纠偏通道；
          # 过期扫描与 seal 扫描同款 100ms 协程粒度
          @steer_registry = Sessions::Scheduling::TurnRegistry.new
          @steer_center = Sessions::Scheduling::SteerCenter.new(@store, @steer_registry,
            -> { steering_policy })
          spawn(name: "sebas-steer-expire-scanner") do
            loop do
              sleep 100.milliseconds
              break if @stopping_scan.get
              begin
                @steer_center.expire_due
              rescue ex
                Log.error(exception: ex) { "steer expire scan failed, next tick continues" }
              end
            end
          end
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
          # fork/join 用户显式触发面接线（M4.1-WP5，Q3：不动生产 agent_turn）：
          # IPC payload → Executor 执行 → 结果 JSON（回执 + expectation 终态）。
          @ipc.fork_handler = ->(payload : JSON::Any) { handle_fork_command(payload) }
          @ipc.steer_handler = ->(session_key : String, payload : String, turn_id : String?, generation : Int64?) do
            @steer_center.submit(session_key, payload, target_turn_id: turn_id, target_generation: generation)
          end
          http_cfg = @config.gateway.http
          @http = Admin::HTTP::Server.new(@channels, @ipc.tap,
            http_cfg.try(&.bind) || "127.0.0.1", http_cfg.try(&.port) || 18790,
            http_cfg.try(&.auth) || "token", ENV["SEBAS_HTTP_TOKEN"]?,
            lifecycle: @lifecycle_store,
            &->trigger_reload)
          @store.recover!
          Sessions::Scheduling::Recovery.recover_stale(@store)
          # steer 恢复口径（M4.5-WP4）：崩溃窗口保守降级——injected 且
          # transcript 无标记 → queued（unknown_not_injected，不伪报成功）
          @steer_center.recover_unconfirmed
          # orchestration 装配置 initialize 尾段（恢复完成后）：组件可达即装配成立；
          # fork 执行体（WP3）/ 回写本体（WP4）/ expectations 判定（WP2）后续包填充，
          # Approvals::Center 装配即通——M4.1 默认只读档无 L3 工具，不触发审批链。
          @agent_registry = Agents::AgentRegistry.new(@data_dir / "agents")
          # 管理面注入（M4.4-WP4）：lifecycle/模板 registry 装配后才可见，
          # IPC/HTTP 两侧同源（构造早于 registry 创建，setter 补注）。
          @ipc.lifecycle_store = @lifecycle_store
          @ipc.template_registry = @agent_registry
          @http.lifecycle = @lifecycle_store
          @http.templates = @agent_registry
          @http.steer_center = @steer_center
          @fork_manager = Orchestration::Fork::ForkManager.new(@store, @agent_registry, @providers, @approvals)
          @join_writer = Orchestration::Fork::JoinWriter.new(@store)
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

          # provider key 热换（下个 turn 生效）；热更新带入的明文同样收敛
          migrate_secrets(new_config)
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
          @stopping_scan.set(true) # 扫描协程先退（在 scheduling/store 关闭前，CodeRabbit）
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
                               event_id : String = "") : String
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
          executor = Tools::Executor.new(registry, @channels)
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
          turn_id = "turn:#{event_id}"
          lease = @steer_registry.register(session_key, turn_id)
          turn_ctx = Agents::TurnContext.new(session_key, lease.turn_id, lease.generation)
          begin
            runtime.run(session_key, turn_ctx, provider, executor, messages, task_id, event_id)
          ensure
            @steer_registry.unregister(session_key, turn_id)
            begin
              @steer_center.flush_to_queue(session_key, turn_id)
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
