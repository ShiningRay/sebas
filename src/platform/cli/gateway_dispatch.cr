# Gateway 调度适配与批次执行（#163，自 gateway.cr 拆分）：
# schedule_input（admission 前置解析）/ run_batch_job（池内批次执行体）/
# message_from_payload（批次输入反序列化）/ consume_bus（总线消费接线）。
# 本 module 由 Gateway include，方法直接访问宿主的 @store/@scheduling/@rules/
# @config 实例变量——拆分只改代码组织，不改行为（issue #163 验收②）。
module Sebas
  module Platform
    module CLI
      module GatewayDispatch
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
