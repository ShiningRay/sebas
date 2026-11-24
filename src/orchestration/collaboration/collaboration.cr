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

      class LoopGuardExceeded < ::Exception; end

      class Messenger
        Log = Sebas::Log.for("sebas.collaboration")

        getter max_hops : Int64
        # 热更新（§11.3 数据类）：配置换值即生效，无需重建 messenger
        setter max_hops : Int64

        @inboxes = Hash(String, Channel(AgentMessage)).new
        @delivered = Hash(String, Array(AgentMessage)).new
        @mutex = Mutex.new

        def initialize(@registry : Agents::AgentRegistry, @store : ::Sebas::Platform::Store::Store,
                       @max_hops : Int64 = DEFAULT_MAX_HOPS, @inbox_capacity : Int32 = 64)
        end

        # 发送 agent 间消息：署名 + hop 计数；超 max_hops 拒发（防互发死循环）。
        # expect_reply=false 语义：接收方产生的回复默认 hop 计入同一链路（不可无限回环）。
        # hops 入参 = 本链路已用跳数（发送方从 ctx 继承，#185），出参 message.hops = hops + 1。
        def send_message(from_agent : String, to_agent : String, content : String,
                         hops : Int64 = 0) : AgentMessage?
          unless @registry.get(to_agent)
            Log.warn { "message_agent: unknown target '#{to_agent}' (from=#{from_agent})" }
            return
          end
          if hops >= @max_hops
            Log.warn { "message_agent: max_hops=#{@max_hops} exceeded (from=#{from_agent} to=#{to_agent} hops=#{hops})" }
            raise LoopGuardExceeded.new("max_hops=#{@max_hops} exceeded (hops=#{hops})")
          end
          signed = "Message from 🤖 #{from_agent}: #{content}"
          delivery_id = "dm:#{::Digest::SHA1.hexdigest("#{from_agent}:#{to_agent}:#{content}:#{Time.utc.to_unix_ms}")}"
          message = AgentMessage.new(delivery_id, from_agent, to_agent, signed, hops + 1)
          receiver_session = ::Sebas::Agents.session_key(to_agent, "internal", "collaboration", from_agent)
          # 先落链路状态再投递：收方消费到消息时下一跳的 hops 已可读（无竞态）
          record_hops(receiver_session, message.hops)
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
          # 显式 hops 仅测试/内部编排可用；生产缺省从 ctx 会话键继承（#185 WP1）
          hops = args["hops"]?.try(&.as_i64?) || @messenger.hops_for(ctx.session_key)
          begin
            message = @messenger.send_message(from, to, content, hops)
            if message
              ::Sebas::Tools::ToolResult.success("queued #{message.delivery_id} hops=#{message.hops}")
            else
              ::Sebas::Tools::ToolResult.error("unknown target agent '#{to}'")
            end
          rescue ex : LoopGuardExceeded
            ::Sebas::Tools::ToolResult.error(ex.message || "loop guard") # 拒发（不投递）
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
