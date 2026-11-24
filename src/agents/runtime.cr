require "../log"
require "../platform/store/store"
require "../providers/providers"
require "../providers/tool_call_parser"
require "../tools/registry"
require "../tools/executor"

module Sebas
  module Agents
    # turn 循环上下文（M4.5-WP4/#6）：turn 身份三元组 + 当前轮次。
    record TurnContext, session_key : String, turn_id : String, generation : Int64, round : Int32 = 0

    # AgentRuntime（M4.5-WP4/#6）：从 Gateway#agent_turn 抽出的 provider/tool
    # 循环运行时。顺序固定：模型响应 → 工具调用 → 工具结果落库 → drain steer
    # → 下一次模型调用——steer 不取消运行中的工具、不篡改参数，只在轮边界
    # 以 user 消息注入（M4.3-WP1 ReAct 循环语义保持不变）。
    class AgentRuntime
      Log = ::Sebas::Log.for("sebas.agents.runtime")

      MAX_TOOL_ROUNDS = 8

      # steer drain 回调（session_key, turn_id, generation → 注入文本列表）；
      # nil = steer 未装配（无注入，行为与 WP4 之前一致）。
      alias SteerDrain = Proc(String, String, Int64, Array(String))

      def initialize(@store : ::Sebas::Platform::Store::Store,
                     @approvals : ::Sebas::Orchestration::Approvals::Center?,
                     @steer_drain : SteerDrain? = nil)
      end

      # 执行一个 turn 的多轮循环，返回终答文本。调用方（Gateway#agent_turn）
      # 负责：history 重建、工具面衰减/装配、provider 获取、system 文本组装、
      # turn 注册/注销与 turn 结束 flush。
      def run(session_key : String, turn : TurnContext,
              provider : Providers::Provider, executor : Tools::Executor,
              messages : Array(Providers::Message), task_id : String?, event_id : String) : String
        (1..MAX_TOOL_ROUNDS).each do |round|
          completion = provider.complete(messages)
          unless completion.ok?
            Log.error { "provider error: #{completion.error}" }
            return "(provider error: #{completion.error})"
          end
          call = Providers::ToolCallParser.parse(completion.text)
          return finish_round(task_id, round, completion.text) if call.nil?

          # 工具调用轮：执行（衰减面）→ 结果持久化 + 回注 → drain steer →
          # checkpoint → 下一轮。每次调用独立幂等标识：入站事件 + 轮次。
          messages += [Providers::Message.new("assistant", completion.text)]
          # 对话上下文人工在场（unattended=false）：L3 审批走 pending 等人
          # 工，approvals 装配使 fork 的 L3 门可达（M4.2-WP3 fail-closed）。
          round_ctx = Tools::ToolContext.new(session_key, "", "#{event_id}:r#{round}", @store,
            nil, @approvals, false, "deny")
          result = executor.run(call.tool, call.args, round_ctx)
          outcome = result.ok? ? result.output : "error: #{result.error}"
          Log.info { "react round #{round}: #{call.tool} -> #{result.ok? ? "ok" : "failed"}" }
          # 工具结果持久化到 transcript（role=tool）——checkpoint 语义 =
          # 「本轮结果已落库」，崩溃重放经 history 重建消息上下文
          @store.append_transcript(session_key, "tool", "#{call.tool}: #{outcome}")
          messages << Providers::Message.new("user", "tool result (#{call.tool}): #{outcome}")
          # drain steer（WP4）：工具结果落库后、下一次模型调用前——轮边界
          # 唯一注入点；注入文本按接收顺序追加为 user 消息
          (@steer_drain.try(&.call(session_key, turn.turn_id, turn.generation)) || [] of String).each do |text|
            messages << Providers::Message.new("user", text)
          end
          @store.checkpoint(task_id, round) if task_id
        end
        # 轮数上限：不再解析工具调用，要求模型给终答
        final = provider.complete(messages + [Providers::Message.new("user",
          "tool round limit (#{MAX_TOOL_ROUNDS}) reached; give your final answer now without tool calls.")])
        final.ok? ? final.text : "(provider error: #{final.error})"
      end

      # 终答轮收尾：checkpoint（终答轮也计入 phase）+ 返回终答
      private def finish_round(task_id : String?, round : Int32, text : String) : String
        @store.checkpoint(task_id, round) if task_id
        text
      end
    end
  end
end
