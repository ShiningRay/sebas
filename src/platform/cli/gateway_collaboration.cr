# Gateway 协作投递（#186 方案 B，Maintainer 裁决「走调度 admission」）：
# admit_collaboration（内部来源独立 admission 分支——不经 schedule_input/binding，
# 不放宽「无 binding 即丢弃」语义）/ run_collaboration_batch（收方协作会话批次执行）/
# process_collaboration_input（intent 三明治 + transcript 执行期落库 + expect_reply 回投）。
# 本 module 由 Gateway include，方法直接访问宿主实例变量（同 gateway_dispatch.cr 模式）。
module Sebas
  module Platform
    module CLI
      module GatewayCollaboration
        Log = Sebas::Log.for("sebas.gateway")

        # 内部消息 admission（#186 方案 B）：收方 agent 存在即入其协作会话批次
        # （queue 模式即封即派）；未知收方拒投并审计（fail-closed 不排队）。
        # duplicate 视同已受理（同 delivery_id 重投幂等，只消费一次）。
        def admit_collaboration(delivery : ::Sebas::Orchestration::Collaboration::Delivery) : Sessions::Scheduling::AdmissionReceipt
          agent = @config.agents[delivery.to_agent]?
          unless agent
            Log.warn { "audit: collaboration delivery dropped, unknown target agent (to=#{delivery.to_agent} from=#{delivery.from_agent} delivery=#{delivery.delivery_id})" }
            return Sessions::Scheduling::AdmissionReceipt.new(delivery.delivery_id, "", "rejected", nil)
          end
          snapshot = Sessions::Scheduling::Policy.resolve_session(@config.gateway.session, agent.session)
          envelope = Sessions::Scheduling::InputEnvelope.new(
            delivery.delivery_id, delivery.session_key, "collaboration", delivery.from_agent, 0,
            ::Time.utc.to_rfc3339, nil, delivery.payload, snapshot
          )
          receipt = scheduling.admit(envelope)
          if receipt.status == "accepted"
            begin
              @lifecycle_store.touch(delivery.session_key, delivery.to_agent, "user")
            rescue ex
              # touch 失败不改 admission 结果（事件已受理；仅元数据缺失）
              Log.warn(exception: ex) { "collaboration lifecycle touch failed (delivery=#{delivery.delivery_id})" }
            end
            Log.info { "collaboration admitted (session=#{delivery.session_key} delivery=#{delivery.delivery_id} batch=#{receipt.batch_id})" }
          end
          receipt
        end

        # 收方协作会话批次执行（run_batch_job 分流）：逐成员还原 Delivery 并
        # 消费；intent 终态收敛批次（与渠道批次同口径）。
        private def run_collaboration_batch(session_key : String, batch_id : String) : Array(String)
          failed = [] of String
          @store.batch_inputs(batch_id).each do |input|
            begin
              delivery = ::Sebas::Orchestration::Collaboration::Delivery.from_payload(input.payload)
              process_collaboration_input(delivery, session_key)
            rescue ex : JSON::ParseException
              Log.error(exception: ex) { "collaboration payload unparsable (event=#{input.event_id})" }
            end
            failed << input.event_id if @store.intent_status(input.event_id) != "done"
          end
          failed
        end

        # 收方消费（#186）：transcript 在执行期落库（admit 持久先于副作用——
        # 崩溃窗口内无孤行，重启循批次/intent 恢复）；收方 turn 在协作会话键下
        # 执行（投递键 = 收方 turn 读键，一致）；终答按 expect_reply 回投或静默。
        private def process_collaboration_input(delivery : ::Sebas::Orchestration::Collaboration::Delivery,
                                                session_key : String, replay : Bool = false) : Nil
          return unless replay || @store.record_intent(delivery.delivery_id, "message", delivery.payload)
          @store.finish_intent(delivery.delivery_id, "dispatched")
          agent_name = session_key.split(":")[1]? || ""
          agent = @config.agents[agent_name]?
          unless agent
            Log.error { "audit: collaboration session targets unknown agent #{agent_name} (delivery=#{delivery.delivery_id})" }
            @store.finish_intent(delivery.delivery_id, "failed")
            return
          end
          if @lifecycle_store.archived?(session_key)
            Log.warn { "audit: write rejected for archived session #{session_key} (delivery=#{delivery.delivery_id})" }
            @store.finish_intent(delivery.delivery_id, "failed")
            return
          end
          # 注入判重（CodeRabbit）：重放路径先查 transcript 是否已有本 delivery
          # 标记行——崩溃于「注入后、intent 完成前」时重放不得重复追加（prompt
          # 含重复消息违反按 ID 幂等消费）；turn 仍继续执行未竟部分
          injected = @store.transcripts(session_key).any? do |row|
            row.role == "user" && row.content.includes?("[delivery: #{delivery.delivery_id}]")
          end
          @store.append_transcript(session_key, "user", delivery.content) unless injected
          task = @store.create_task("turn:#{delivery.delivery_id}", "turn", payload: delivery.payload)
          begin
            reply = agent_turn(agent_name, agent, session_key, task_id: task.id, event_id: delivery.delivery_id)
            @store.append_transcript(session_key, "agent", reply)
            @store.complete_task(task.id, reply)
            route_collaboration_reply(agent_name, delivery, reply)
            @store.finish_intent(delivery.delivery_id, "done")
          rescue ex : ::Exception
            Log.error(exception: ex) { "collaboration turn failed (delivery=#{delivery.delivery_id})" }
            @store.fail_task(task.id, ex.message)
            @store.finish_intent(delivery.delivery_id, "failed")
          end
        end

        # expect_reply 回投发送方（#186）：默认 false 静默（单向通知无回声链）；
        # true 时终答经同一 admission 分支入发送方协作会话，hops 继承（防环上限
        # 沿用）；回投自身 expect_reply=false（不可再回投）。拒投/超跳审计不炸 turn。
        private def route_collaboration_reply(recipient : String,
                                              delivery : ::Sebas::Orchestration::Collaboration::Delivery,
                                              reply : String) : Nil
          return unless delivery.expect_reply
          return if reply.strip.empty?
          messenger = @collaboration_messenger
          unless messenger
            Log.warn { "audit: collaboration reply dropped, messenger unwired (delivery=#{delivery.delivery_id})" }
            return
          end
          begin
            messenger.send_message(recipient, delivery.from_agent, reply, delivery.hops, false)
          rescue ::Sebas::Orchestration::Collaboration::LoopGuardExceeded
            Log.warn { "audit: collaboration reply dropped, loop guard (delivery=#{delivery.delivery_id} hops=#{delivery.hops})" }
          rescue ex : ::Exception
            Log.error(exception: ex) { "audit: collaboration reply delivery failed (delivery=#{delivery.delivery_id})" }
          end
        end
      end
    end
  end
end
