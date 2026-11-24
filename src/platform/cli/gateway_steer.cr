require "json"
require "./gateway_dispatch"
require "../../sessions/scheduling/steer"
require "../../sessions/scheduling/policy"
require "../../log"

module Sebas
  module Platform
    module CLI
      # busy steer 接线（M4.5-WP4，自 gateway_dispatch 拆分——CodeRabbit
      # RB-I 400 行闸）：/steer 命令入口 + queued outbox 派发扫描器 + 策略
      # 快照。include mixin，实例变量由宿主 Gateway 提供（@store/@config/
      # @steer_center/@steer_registry/@steer_dispatch_ready/@scheduling/
      # @lifecycle_store/@bus）。
      module GatewaySteer
        Log = Sebas::Log.for("sebas.gateway")

        # 显式 /steer 命令（M4.5-WP4）：明确 correction 语义入口——普通
        # 聊天正文不靠关键词/LLM 猜测纠偏意图；回执经提交状态落库。
        # steer_id 派生自 event_id：重放（intent dispatched 崩溃兜底）时
        # INSERT OR IGNORE 主键相同，不产生第二行（CodeRabbit PQMw）。
        # 返回 true = 已按 steer 处理（调用方直接返回）。
        private def handle_steer_command(message : Bus::InboundMessage, session_key : String,
                                         record_intent : Bool = false) : Bool
          return false unless message.content.starts_with?("/steer ")
          if record_intent
            unless @store.record_intent(message.event_id, "message", message.to_json)
              # 重复投递：done=原提交已完成只收口；dispatched=首次提交未完成
              # （落库后崩溃），用稳定 steer_id 继续幂等提交（CodeRabbit P2Zd）
              next_status = @store.intent_status(message.event_id)
              if next_status == "done"
                return true
              end
            end
          end
          if @lifecycle_store.archived?(session_key)
            Log.warn { "audit: steer rejected for archived session #{session_key} (event=#{message.event_id})" }
            @store.finish_intent(message.event_id, "failed")
            return true
          end
          steer_payload = message.content[7..].to_s.strip
          receipt = @steer_center.submit(session_key, steer_payload,
            steer_id: "steer-#{message.event_id}")
          Log.info { "steer submitted (event=#{message.event_id} id=#{receipt.steer_id} status=#{receipt.status} reason=#{receipt.reason})" }
          # queued（outbox）由派发扫描器统一接管（100ms 粒度，持久可重试），
          # 各入口语义一致——此处只收口 intent（CodeRabbit P2Zb/P2Zo）
          @store.finish_intent(message.event_id, "done")
          true
        end

        # queued steer 派发扫描器（M4.5-WP4 outbox，三轮 QWvD/QWvI/QWvO +
        # 四轮 RB-Q 组标记持久化）
        # ameba:disable Metrics/CyclomaticComplexity — 分组派发直译（agent/归档/blocked/容量逐层闸）
        private def dispatch_due_steers : Nil
          return unless @steer_dispatch_ready.get
          # 组键：已有 dispatch_event_id 的行沿用原组（崩溃恢复按原 event_id
          # duplicate 幂等，不按剩余成员重算组头——四轮 RB-Q）；无标记行按
          # 会话归入一个新组（组头 = 会话内首个无标记行）
          groups = Hash(String, Array(::Sebas::Platform::Store::Store::SessionSteerRow)).new
          new_group = Hash(String, String).new
          @store.steers_with_status("queued").each do |row|
            key = row.dispatch_event_id
            unless key
              key = new_group[row.session_key]?
              unless key
                key = "new:#{row.steer_id}"
                new_group[row.session_key] = key
              end
            end
            groups[key] ||= Array(::Sebas::Platform::Store::Store::SessionSteerRow).new
            groups[key] << row # 数组序 = created_at,rowid（接收序）
          end
          blocked = Set(String).new
          groups.each do |_key, group|
            session_key = group.first.session_key
            agent_name = session_key.split(":")[1]? || ""
            agent = @config.agents[agent_name]?
            unless agent
              group.each do |row|
                @store.transition_session_steer(row.steer_id,
                  ::Sebas::Sessions::Scheduling::SteerStatus::Queued,
                  ::Sebas::Sessions::Scheduling::SteerStatus::Rejected, "unknown agent for session")
              end
              next
            end
            if @lifecycle_store.archived?(session_key)
              group.each do |row|
                @store.transition_session_steer(row.steer_id,
                  ::Sebas::Sessions::Scheduling::SteerStatus::Queued,
                  ::Sebas::Sessions::Scheduling::SteerStatus::Rejected, "archived session")
              end
              next
            end
            next if blocked.includes?(session_key)
            # 已标记组（历史 E）先查原事件是否已入批：已入批按原输入恢复
            # 确认——必须在预算拒绝等状态修改**之前**（否则崩溃窗口 + policy
            # 调小会让超限行先 rejected，queued→dispatched CAS 无路可走，
            # CodeRabbit 七轮）；未入批组才执行预算校验与重拆。
            marked_event = group.first.dispatch_event_id
            if marked_event && @store.session_input?(marked_event)
              group.each do |row|
                @store.transition_session_steer(row.steer_id,
                  ::Sebas::Sessions::Scheduling::SteerStatus::Queued,
                  ::Sebas::Sessions::Scheduling::SteerStatus::Dispatched,
                  "recovered confirm (input exists: #{marked_event})")
              end
              next
            end
            # 字节预算拆分（五轮 RtPy）：合成输入超 policy.max_bytes 会被
            # admit 永拒（组固定 event_id + blocked → 永久阻塞）。标记前按
            # 预算切子组；单条超限显式 rejected（oversized）不静默丢弃。
            budget = Sessions::Scheduling::Policy.resolve_session(@config.gateway.session, agent.session).max_bytes
            subgroups = Array(Array(::Sebas::Platform::Store::Store::SessionSteerRow)).new
            current = Array(::Sebas::Platform::Store::Store::SessionSteerRow).new
            current_bytes = 0
            group.each do |row|
              row_bytes = row.payload.bytesize + 96 # marker/id/换行余量
              if row_bytes > budget
                @store.transition_session_steer(row.steer_id,
                  ::Sebas::Sessions::Scheduling::SteerStatus::Queued,
                  ::Sebas::Sessions::Scheduling::SteerStatus::Rejected, "oversized payload")
                Log.warn { "oversized steer rejected (session=#{session_key} steer=#{row.steer_id} bytes=#{row_bytes})" }
                next
              end
              if current_bytes + row_bytes > budget && !current.empty?
                subgroups << current
                current = Array(::Sebas::Platform::Store::Store::SessionSteerRow).new
                current_bytes = 0
              end
              current << row
              current_bytes += row_bytes
            end
            subgroups << current unless current.empty?

            subgroups.each do |sub|
              head = sub.first
              parts = session_key.split(":", 5) # 第五段保留完整 peer（分身 peer 含冒号）
              # 未入批已标记组重拆：子组用新独立 id（head.steer_id 唯一，
              # mark 覆盖旧标记为子组新 id，恢复按新 id 幂等）
              event_id = marked_event ? "steer-dispatch-#{head.steer_id}-r#{subgroups.index(sub)}" : "steer-dispatch-#{head.steer_id}"
              # 事务内原子写全组标记（部分命中=并发确认过，本轮跳过）
              next unless @store.mark_steer_dispatch_group(sub.map(&.steer_id), event_id)
              content = sub.map { |row| "[steer replay #{row.steer_id}] #{row.payload}" }.join("\n")
              envelope = Sessions::Scheduling::InputEnvelope.new(
                event_id, session_key, parts[3]? || "", parts[4]? || "", 0,
                ::Time.utc.to_rfc3339, nil,
                Bus::InboundMessage.new(event_id, parts[3]? || "", parts[2]? || "",
                  parts[4]? || "", content).to_json,
                Sessions::Scheduling::Policy.resolve_session(@config.gateway.session, agent.session)
              )
              receipt = scheduling.admit(envelope)
              if receipt.status == "accepted" || receipt.status == "duplicate"
                sub.each do |row|
                  @store.transition_session_steer(row.steer_id,
                    ::Sebas::Sessions::Scheduling::SteerStatus::Queued,
                    ::Sebas::Sessions::Scheduling::SteerStatus::Dispatched,
                    "dispatched to batch (#{receipt.status})")
                end
                Log.info { "queued steer group dispatched (session=#{session_key} count=#{sub.size} admission=#{receipt.status})" }
              else
                # 容量满等拒绝：整组保持 queued，下轮同 event_id 重试；blocked
                # + break 防本轮后续子组越过未入批前项（CodeRabbit SM7O/QWvI）
                blocked << session_key
                Log.warn { "queued steer dispatch deferred (session=#{session_key} count=#{sub.size} admission=#{receipt.status})" }
                break
              end
            end
          end
        rescue ex
          Log.error(exception: ex) { "steer dispatch scan failed, next tick continues" }
        end

        # IPC steer_handler 接线（gateway 构造调用）
        def wire_steer_handler : Nil
          @ipc.steer_handler = ->(session_key : String, payload : String, turn_id : String?, generation : Int64?) do
            @steer_center.submit(session_key, payload, target_turn_id: turn_id, target_generation: generation)
          end
        end

        # steer 策略快照（SteerCenter 过期扫描/drain 判定用）：沿用调度链
        # 解析口径（内置 → gateway.session → agents.<name>.session）
        private def steering_policy(session_key : String? = nil) : Sessions::Scheduling::PolicySnapshot
          config = Config::CURRENT.get
          agent_name = session_key.try(&.split(":")[1]?) || "main"
          agent = config.agents[agent_name]?
          Sessions::Scheduling::Policy.resolve_session(config.gateway.try(&.session), agent.try(&.session))
        end
      end
    end
  end
end
