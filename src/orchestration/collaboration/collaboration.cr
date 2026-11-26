require "digest/sha1"
require "json"
require "../../agents/agents"
require "../../tools/registry"
require "../../platform/store/store"
require "../../log"

# agent 间消息（M3-WP2，design.md §8.1，Hermes Bot Mode 三件套）：
# fire-and-forget（发送方收 ack=queued + delivery_id）+ 署名（Message from 🤖 <id>:）+
# max_hops 防环（默认 4，超限拒发）+ 回复默认不可再被回复（单向通知不产生回声链）。
module Sebas
  module Orchestration
    module Collaboration
      DEFAULT_MAX_HOPS = 4_i64

      # 链路已用跳数（收方会话键 → 跳数）：投递时写，下一跳从 ctx 会话键继承
      # （#185 WP1 跨跳累加——hops 不再由模型自报）。
      HOP_MEMO_PREFIX = "collab:hops:"

      record AgentMessage, delivery_id : String, from_agent : String, to_agent : String,
        content : String, hops : Int64

      # 投递载荷（#186 方案 B）：Messenger 组装，经 Gateway#admit_collaboration
      # 入收方协作会话调度批次；payload JSON 即调度信封载荷，收方批次执行
      # （run_collaboration_batch）按此还原。字段名与 Bus::InboundMessage 对齐
      # （event_id/channel_type/account_id/peer/content），误入渠道解析路径也可读。
      record Delivery, delivery_id : String, from_agent : String, to_agent : String,
        session_key : String, content : String, hops : Int64, expect_reply : Bool,
        payload : String do
        def self.build(delivery_id : String, from_agent : String, to_agent : String,
                       session_key : String, content : String, hops : Int64,
                       expect_reply : Bool) : Delivery
          payload = {
            "kind":         "collaboration",
            "event_id":     delivery_id,
            "delivery_id":  delivery_id,
            "channel_type": "collaboration",
            "account_id":   "internal",
            "peer":         from_agent,
            "session_key":  session_key,
            "from_agent":   from_agent,
            "to_agent":     to_agent,
            "content":      content,
            "hops":         hops,
            "expect_reply": expect_reply,
          }.to_json
          new(delivery_id, from_agent, to_agent, session_key, content, hops, expect_reply, payload)
        end

        def self.from_payload(raw : String) : Delivery
          data = JSON.parse(raw)
          hops = data["hops"]?.try(&.as_i64?) || 0_i64
          expect_reply = data["expect_reply"]?.try(&.as_bool?) || false
          new(
            data["delivery_id"].as_s, data["from_agent"].as_s, data["to_agent"].as_s,
            data["session_key"].as_s, data["content"].as_s, hops, expect_reply, raw
          )
        end
      end

      class LoopGuardExceeded < ::Exception; end

      # admission 拒投（#186：容量满/会话关闭等 fail-closed）——发送方无 ack 可重试
      class DeliveryRejected < ::Exception; end

      class Messenger
        Log = Sebas::Log.for("collaboration")

        getter max_hops : Int64
        # 热更新（§11.3 数据类）：配置换值即生效，无需重建 messenger
        setter max_hops : Int64

        @inboxes = Hash(String, Channel(AgentMessage)).new
        @delivered = Hash(String, Array(AgentMessage)).new
        @mutex = Mutex.new
        # 投递接线（#186 方案 B）：生产由 Gateway 注入——内部消息经独立
        # admission 分支入收方协作会话调度批次（持久，崩溃可恢复）；
        # 未接线时保留 #185 直投口径（transcript + 内存 inbox，测试/工具单测）。
        @deliver : Proc(Delivery, Bool)? = nil

        def initialize(@registry : Agents::AgentRegistry, @store : ::Sebas::Platform::Store::Store,
                       @max_hops : Int64 = DEFAULT_MAX_HOPS, @inbox_capacity : Int32 = 64)
        end

        setter deliver : Proc(Delivery, Bool)?

        # 发送 agent 间消息：署名（含 delivery 标记，收方 turn 上下文可见）+
        # hop 计数；超 max_hops 拒发（防互发死循环）。
        # expect_reply（#186）：默认 false 单向通知（不产生回声链）；true 时
        # 收方 turn 的终答回投发送方（回投本身不再可回投，hops 继承防环）。
        # hops 入参 = 本链路已用跳数（发送方从 ctx 继承，#185），出参 message.hops = hops + 1。
        # 已接线时投递经 admission：拒投 raise DeliveryRejected（发送方无 ack 可重试）。
        def send_message(from_agent : String, to_agent : String, content : String,
                         hops : Int64 = 0, expect_reply : Bool = false) : AgentMessage?
          unless @registry.get(to_agent)
            Log.warn { "message_agent: unknown target '#{to_agent}' (from=#{from_agent})" }
            return
          end
          if hops >= @max_hops
            Log.warn { "message_agent: max_hops=#{@max_hops} exceeded (from=#{from_agent} to=#{to_agent} hops=#{hops})" }
            raise LoopGuardExceeded.new("max_hops=#{@max_hops} exceeded (hops=#{hops})")
          end
          # 每次独立发送唯一（随机分量）：同毫秒同内容不撞 id；重投同一条消息
          # 复用其 id，调度层按 id 幂等（duplicate 只消费一次）
          delivery_id = "dm:#{::Digest::SHA1.hexdigest("#{from_agent}:#{to_agent}:#{content}:#{Time.utc.to_unix_ms}:#{::Random::Secure.hex(8)}")}"
          signed = "Message from 🤖 #{from_agent}: #{content}\n[delivery: #{delivery_id}]"
          message = AgentMessage.new(delivery_id, from_agent, to_agent, signed, hops + 1)
          receiver_session = ::Sebas::Agents.session_key(to_agent, "internal", "collaboration", from_agent)
          # 先落链路状态再投递：收方消费到消息时下一跳的 hops 已可读（无竞态）
          record_hops(receiver_session, message.hops)
          if callback = @deliver
            delivery = Delivery.build(delivery_id, from_agent, to_agent, receiver_session,
              signed, message.hops, expect_reply)
            return message if callback.call(delivery)
            raise DeliveryRejected.new("collaboration delivery rejected (delivery=#{delivery_id})")
          end
          # 未接线（#185 直投口径）：transcript 直落 + 内存 inbox（不进调度）
          @store.append_transcript(receiver_session, "user", signed)
          inbox_for(to_agent).send(message)
          message
        end

        # 接收方取下一条（分片 inbox：只取本 agent 的消息，#185 WP1）
        def receive?(agent_id : String, timeout : Time::Span = 1.seconds) : AgentMessage?
          inbox = inbox_for(agent_id)
          select
          when message = inbox.receive
            track(message)
            message
          when timeout timeout
            nil
          end
        end

        # 本会话所在链路的已用跳数（#185）：上一跳投递时按收方会话键落库，
        # MessageAgentTool 缺省 hops 由此派生（模型不再自报，防绕过防环上限）。
        def hops_for(session_key : String) : Int64
          @store.memo_get("#{HOP_MEMO_PREFIX}#{session_key}").try(&.to_i64?) || 0_i64
        end

        private def record_hops(session_key : String, hops : Int64) : Nil
          @store.memo_replace("#{HOP_MEMO_PREFIX}#{session_key}", hops.to_s)
        end

        # 收件人分片通道（per to_agent）：懒创建，避免收方互相取走消息
        private def inbox_for(agent_id : String) : Channel(AgentMessage)
          @mutex.synchronize do
            @inboxes[agent_id] ||= Channel(AgentMessage).new(@inbox_capacity)
          end
        end

        private def track(message : AgentMessage) : Nil
          @mutex.synchronize do
            list = @delivered[message.to_agent]? || [] of AgentMessage
            list << message
            @delivered[message.to_agent] = list
          end
        end

        def delivered_to(agent_id : String) : Array(AgentMessage)
          @mutex.synchronize { @delivered.fetch(agent_id, [] of AgentMessage).dup }
        end
      end

      # 内置工具 message_agent（工具面注册；hops 从 ctx 继承——防环计数跨跳累加）
      class MessageAgentTool < ::Sebas::Tools::Tool
        NAME = "message_agent"

        getter messenger : Messenger

        def initialize(@messenger : Messenger)
          super(NAME, "Send a fire-and-forget message to another agent (max_hops guard)",
            ::Sebas::Tools::ReplaySemantics::Effectful, ::Sebas::Tools::Risk::Medium)
        end

        def run(args : JSON::Any, ctx : ::Sebas::Tools::ToolContext) : ::Sebas::Tools::ToolResult
          to = args["agent"]?.try(&.as_s?)
          content = args["content"]?.try(&.as_s?)
          return ::Sebas::Tools::ToolResult.error("agent/content are required") unless to && content
          from = ctx.session_key.split(":")[1]? || "main"
          # expect_reply（#186）：缺省 false——单向通知不产生回声链
          expect_reply = args["expect_reply"]?.try(&.as_bool?) || false
          # 显式 hops 仅测试/内部编排可用；生产缺省绑定启动本 turn 的 delivery
          # （ctx.collab_hops，#186 CodeRabbit：会话 memo 会被同会话新链路覆盖，
          # 在途 turn 读到旧值会绕过防环上限）；memo 仅遗留会话兜底
          hops = args["hops"]?.try(&.as_i64?) || ctx.collab_hops || @messenger.hops_for(ctx.session_key)
          begin
            message = @messenger.send_message(from, to, content, hops, expect_reply)
            if message
              ::Sebas::Tools::ToolResult.success("queued #{message.delivery_id} hops=#{message.hops}")
            else
              ::Sebas::Tools::ToolResult.error("unknown target agent '#{to}'")
            end
          rescue ex : LoopGuardExceeded
            ::Sebas::Tools::ToolResult.error(ex.message || "loop guard") # 拒发（不投递）
          rescue ex : DeliveryRejected
            ::Sebas::Tools::ToolResult.error("collaboration delivery rejected: #{ex.message}") # 无 ack 可重试
          end
        end
      end

      # 工具面装配入口（#185 WP1）：messenger 未接线则不注册（返回 false）——
      # 不出现「白名单有、执行无」；注册后与全局同受 agent.tools.allow 裁剪
      # （Tools::Registry#restrict_to）。GatewayDispatch#attenuated_registry 调用本方法。
      def self.register_tool_face(registry : ::Sebas::Tools::Registry,
                                  messenger : Messenger?) : Bool
        return false unless messenger
        registry.register(MessageAgentTool.new(messenger))
        true
      end
    end
  end
end
