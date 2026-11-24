# Gateway 调度适配与批次执行（#163，自 gateway.cr 拆分）：
# schedule_input（admission 前置解析）/ run_batch_job（池内批次执行体）/
# message_from_payload（批次输入反序列化）/ consume_bus（总线消费接线）/
# handle_fork_command（IPC fork 触发面，#49 迁入——同为入站触发接线）。
# 本 module 由 Gateway include，方法直接访问宿主的 @store/@scheduling/@rules/
# @config 实例变量——拆分只改代码组织，不改行为（issue #163 验收②）。
module Sebas
  module Platform
    module CLI
      module GatewayDispatch
        # 词法作用域提示：module 内 Log 按定义处解析，看不到 Gateway 类的
        # Log 常量——须显式声明同源 logger，保迁移后 admission/批次/消费日志
        # 仍挂 sebas.gateway 来源（CodeRabbit PRRT_kwDOVzNPQM66vjmM）。
        Log = Sebas::Log.for("sebas.gateway")

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

        # 前台 admission（M4.3-WP3）：复用 Scheduler.admit 同一事务路径——
        # 会话键用前台专用前缀（匿名/临时包装），agent 固定前台配置。
        private def admit_to_front_desk(event : Bus::InboundMessage) : Nil
          agent_name = ::Sebas::Agents::Reception::FRONT_DESK_AGENT
          agent = @config.agents[agent_name]?
          return unless agent # 理论不可达（调用方已判）
          session_key = ::Sebas::Agents::Reception.session_key_for(
            event.channel_type, event.account_id, event.peer
          )
          snapshot = Sessions::Scheduling::Policy.resolve_session(@config.gateway.session, agent.session)
          envelope = Sessions::Scheduling::InputEnvelope.new(
            event.event_id, session_key, event.channel_type, event.peer, 0,
            ::Time.utc.to_rfc3339, nil, event.to_json, snapshot
          )
          receipt = scheduling.admit(envelope)
          begin
            @lifecycle_store.touch(session_key, agent_name, "user") if receipt.status == "accepted"
          rescue ex
            # touch 失败不改 admission 结果（事件已受理可派发；仅元数据缺失）
            Log.warn(exception: ex) { "reception lifecycle touch failed (event=#{event.event_id})" }
          end
          Log.info { "reception admitted (session=#{session_key} event=#{event.event_id} status=#{receipt.status})" } if receipt.status == "accepted"
        end

        # admission 前置解析（契约 §4.2：Router 在 admission 前完成 agent/session 解析；
        # 无 binding 仍 fail-closed 丢弃并审计，不能先占队列）→ Scheduler.admit，
        # SQLite 事务成功才接受；重复投递幂等；容量超限拒绝并计数。
        private def schedule_input(event : Bus::InboundMessage) : Nil
          agent_name = Routing::Table.resolve(@rules, event.channel_type, event.account_id, event.peer)
          unless agent_name
            # 前台接待（M4.3-WP3 §1.1）：配置了前台 agent 时，无 binding 消息
            # 改投前台（匿名/临时会话包装，Session 藏而不删）；原 fail-closed
            # 审计保留——无前台配置时行为与 M0 一致（丢弃 + 审计）。
            if @config.agents[::Sebas::Agents::Reception::FRONT_DESK_AGENT]?
              Log.info { "reception: inbound without binding routed to front desk (channel=#{event.channel_type} peer=#{event.peer} event=#{event.event_id})" }
              admit_to_front_desk(event)
              return
            end
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
          begin
            @lifecycle_store.touch(session_key, agent_name, "user") if receipt.status == "accepted"
          rescue ex
            # touch 失败不改 admission 结果（同上）
            Log.warn(exception: ex) { "lifecycle touch failed (event=#{event.event_id})" }
          end
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

        # IPC fork 命令处理（M4.1-WP5）：payload 字段 task/count/mode/deadline/
        # window；路由到当前装配的 ForkManager/Executor，join 回写由 Expectations
        # + JoinWriter 在终态判定后落父会话（默认父会话 = 命令指定或 "agent:main:internal:main:fork-cli"）。
        def handle_fork_command(payload : JSON::Any) : JSON::Any # payload = frame.data 包裹为 JSON::Any.new(hash)
          data = payload.as_h? || {} of String => JSON::Any
          input, parent_session = parse_fork_input(data)
          main_agent = @config.agents["main"]?
          raise ::Sebas::Platform::Store::StoreError.new("fork 命令缺 main agent 配置") if main_agent.nil?
          parent_allow = main_agent.tools.try(&.allow) || ["*"]
          executor = Orchestration::Fork::Executor.new(@store, Orchestration::Fork::Expectations.new(@store),
            -> { @providers.for_agent("main") { @provider_factory.call(main_agent, nil) } },
            approvals: @approvals)
          results = executor.run(
            "cli-fork", parent_session, "main", "", "", input, parent_allow
          )
          grant = executor.last_grant
          JSON.parse({
            "fork_id" => results.first?.try(&.task_id.split(":")[0...2].join(":")).to_s,
            # 数组直接入对象，仅外层序列化一次——嵌套 to_json 会让客户端
            # 拿到双重编码的字符串（CodeRabbit PRRT_kwDOVzNPQM662088）。
            "tools_effective" => (grant.try(&.effective) || [] of String),
            "tools_removed"   => (grant.try(&.removed) || [] of String),
            "members"         => results.map { |result| {"task_id" => result.task_id, "state" => result.state}.to_json },
          }.to_json)
        end

        # payload 字段解析（task/count/mode/deadline/window/role/tools）→
        # SnapshotBuilder::Input；独立成方法控 handle_fork_command 圈复杂度。
        private def parse_fork_input(data : Hash(String, JSON::Any)) : Tuple(Orchestration::Fork::SnapshotBuilder::Input, String)
          task = data["task"]?.try(&.as_s?) || ""
          raise ::Sebas::Platform::Store::StoreError.new("fork 命令缺 task") if task.empty?
          # 区分缺失与类型错误（CodeRabbit）：缺失用默认 1；存在但非整数
          # （字符串/浮点）拒绝，不被默认值吞掉。
          count = if raw_count = data["count"]?
                    raw_count.as_i? ||
                      raise ::Sebas::Platform::Store::StoreError.new(
                        "count 必须为整数，实际：#{raw_count}")
                  else
                    1
                  end
          raise ::Sebas::Platform::Store::StoreError.new("count 必须为正整数，实际：#{count}") if count <= 0
          max_concurrent = ::Sebas::Orchestration::Fork::Executor::DEFAULT_MAX_CONCURRENT
          raise ::Sebas::Platform::Store::StoreError.new(
            "count #{count} 超过分身并发闸 #{max_concurrent}（超限整体拒绝，不排队）") if count > max_concurrent
          mode = data["mode"]?.try(&.as_s?) || "allSettled"
          deadline = data["deadline"]?.try(&.as_i?) || 3600
          parent_session = data["parent_session"]?.try(&.as_s?) || "agent:main:internal:main:fork-cli"
          # 工具声明（M4.2-WP1 §5.2）：缺失 = 默认只读档；类型错（非字符串数组）
          # 整体拒绝，不被默认值吞掉。
          tools = parse_fork_string_list(data, "tools")
          # 工作区文件清单（M4.2-WP2 §2.2 L1）：fork 开始对这些文件记指纹，
          # join 回写对比冲突。缺失 = 无指纹快照（只读 fork 不需要）。
          files = parse_fork_string_list(data, "files")

          input = Orchestration::Fork::SnapshotBuilder::Input.new(
            task: task, count: count, window: data["window"]?.try(&.as_i?),
            include: nil, tools: tools, role: data["role"]?.try(&.as_s?),
            mode: mode, deadline: deadline, files: files
          )
          {input, parent_session}
        end

        # 可选字符串数组字段解析：缺失返回 nil；存在但非字符串数组整体拒绝
        # （与 count 同款「区分缺失与类型错误」口径）。
        private def parse_fork_string_list(data : Hash(String, JSON::Any), field : String) : Array(String)?
          raw = data[field]? || return
          unless raw.as_a?.try(&.all?(&.as_s?))
            raise ::Sebas::Platform::Store::StoreError.new(
              "#{field} 必须为字符串数组，实际：#{raw}")
          end
          raw.as_a.map(&.as_s)
        end

        # 对话流内自然 fork（M4.3-WP2 §6.1）：fork 工具进父 agent ReAct 面
        # （经衰减/并发闸/一级限制/L3 审批四重闸）；分身面不注册（一级限制）。
        private def register_dialog_fork_tool(registry : Tools::Registry,
                                              agent_name : String, agent : Config::AgentConfig) : Nil
          main_agent = @config.agents[agent_name]?
          return unless main_agent
          registry.register(Tools::ForkTool.new(@store,
            Orchestration::Fork::Expectations.new(@store),
            -> { @providers.for_agent(agent_name) { @provider_factory.call(agent, nil) } },
            @approvals, agent_name,
            main_agent.tools.try(&.allow) || ["*"]))
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

        # 终答轮收尾：checkpoint（终答轮也计入 phase）+ 返回终答
        private def finish_round(task_id : String?, round : Int32, text : String) : String
          @store.checkpoint(task_id, round) if task_id
          text
        end

        # 衰减工具面（M4.3-WP1）：agent.tools.allow 白名单过滤（"*" 现状
        # 口径 = 全量）——白名单外工具从注册表移除，工具面即生效面
        private def attenuated_registry(agent : Config::AgentConfig) : Tools::Registry
          registry = Tools.default_registry(@channels)
          allowed = agent.tools.try(&.allow) || ["*"]
          unless allowed.includes?("*")
            registry.names.each do |name|
              registry.unregister(name) unless allowed.includes?(name)
            end
          end
          registry
        end

        # 工具协议提示（M4.3-WP1）：可用工具清单 + fenced JSON 调用格式——
        # 模型据此发起工具调用（新会话无工具知识则循环永不触发）。
        # 前台默认档（M4.3-WP3）：只读工具面——移除全部非只读工具
        # （写副作用/网络写/不可逆均不出前台）
        private def restrict_registry_to_read_only(registry : Tools::Registry) : Nil
          registry.names.reject { |name| ::Sebas::Agents::Reception::READ_ONLY_TOOLS.includes?(name) }.each do |name|
            registry.unregister(name)
          end
        end

        private def tool_protocol_prompt(registry : Tools::Registry) : String
          String.build do |io|
            io << "You can call tools. Available tools:\n"
            io << registry.describe << "\n\n"
            io << "To call a tool, respond with exactly one fenced JSON block:\n"
            io << "```json\n{\"tool\": \"<name>\", \"args\": {<parameters>}}\n```\n"
            io << "The tool result will be provided in the next message. Respond without such a block to give your final answer. Note: string values must not contain ``` sequences."
          end
        end

        private def build_rules(config : Config::Config) : Array(Routing::BindingRule)
          config.bindings.map do |b|
            Routing::BindingRule.new(b.channel, b.account || "*", b.peer || "*", b.agent)
          end
        end

        # 重放未完成 intents（崩溃恢复入口，M0-WP8 演练；#49 迁入 dispatch——
        # 与 schedule_input 同为入站消息接线）
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
      end
    end
  end
end
