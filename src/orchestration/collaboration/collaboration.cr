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

      record AgentMessage, delivery_id : String, from_agent : String, to_agent : String,
        content : String, hops : Int64

      class LoopGuardExceeded < ::Exception; end

      class Messenger
        Log = Sebas::Log.for("sebas.collaboration")

        getter inbox : Channel(AgentMessage)
        getter max_hops : Int64

        @delivered = Hash(String, Array(AgentMessage)).new
        @mutex = Mutex.new

        def initialize(@registry : Agents::AgentRegistry, @store : ::Sebas::Platform::Store::Store,
                       @max_hops : Int64 = DEFAULT_MAX_HOPS, inbox_capacity : Int32 = 64)
          @inbox = Channel(AgentMessage).new(inbox_capacity)
        end

        # 发送 agent 间消息：署名 + hop 计数；超 max_hops 拒发（防互发死循环）。
        # expect_reply=false 语义：接收方产生的回复默认 hop 计入同一链路（不可无限回环）。
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
          @inbox.send(message)
          @store.append_transcript(
            ::Sebas::Agents.session_key(to_agent, "internal", "collaboration", from_agent),
            "user", signed
          )
          message
        end

        # 接收方取下一条（模型：收方 agent turn 消费 inbox）
        def receive?(timeout : Time::Span = 1.seconds) : AgentMessage?
          select
          when message = @inbox.receive
            track(message)
            message
          when timeout timeout
            nil
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

      # 内置工具 message_agent（工具面注册；hops 从消息载荷继承——防环计数跨跳累加）
      class MessageAgentTool < ::Sebas::Tools::Tool
        getter messenger : Messenger

        def initialize(@messenger : Messenger)
          super("message_agent", "Send a fire-and-forget message to another agent (max_hops guard)",
            ::Sebas::Tools::ReplaySemantics::Effectful, ::Sebas::Tools::Risk::Medium)
        end

        def run(args : JSON::Any, ctx : ::Sebas::Tools::ToolContext) : ::Sebas::Tools::ToolResult
          to = args["agent"]?.try(&.as_s?)
          content = args["content"]?.try(&.as_s?)
          hops = args["hops"]?.try(&.as_i?) || 0
          return ::Sebas::Tools::ToolResult.error("agent/content are required") unless to && content
          from = ctx.session_key.split(":")[1]? || "main"
          begin
            message = @messenger.send_message(from, to, content, hops.to_i64)
            message ? ::Sebas::Tools::ToolResult.success("queued #{message.delivery_id}") : ::Sebas::Tools::ToolResult.error("unknown target agent '#{to}'")
          rescue ex : LoopGuardExceeded
            ::Sebas::Tools::ToolResult.error(ex.message || "loop guard") # 拒发（不投递）
          end
        end
      end
    end
  end
end
