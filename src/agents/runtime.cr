require "json"
require "../log"
require "../platform/store/store"
require "../plugins/hook_bus"
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
      Log = ::Sebas::Log.for("agents.runtime")

      MAX_TOOL_ROUNDS = 8

      # steer drain 回调（session_key, turn_id, generation → 注入文本列表）；
      # nil = steer 未装配（无注入，行为与 WP4 之前一致）。
      alias SteerDrain = Proc(String, String, Int64, Array(String))

      # hook 门面（M3-WP5，#17）：agent×2 + llm×4 注入；缺省 disabled 零开销
      property hook_bus : ::Sebas::Plugins::HookBus = ::Sebas::Plugins::HookBus.disabled

      def initialize(@store : ::Sebas::Platform::Store::Store,
                     @approvals : ::Sebas::Orchestration::Approvals::Center?,
                     @steer_drain : SteerDrain? = nil)
      end

      # 执行一个 turn 的多轮循环，返回终答文本。调用方（Gateway#agent_turn）
      # 负责：history 重建、工具面衰减/装配、provider 获取、system 文本组装、
      # turn 注册/注销与 turn 结束 flush。
      def run(session_key : String, turn : TurnContext,
              provider : Providers::Provider, executor : Tools::Executor,
              messages : Array(Providers::Message), task_id : String?, event_id : String,
              collab_hops : Int64? = nil) : String
        # agent.turn.before（M3-WP5，#17 §12.11 gate）：可拒绝整个 turn
        verdict = hook_bus.gate("agent.turn.before", hook_context(session_key),
          JSON.parse(%({"agent_id": #{agent_id_of(session_key).inspect}, "session_key": #{session_key.inspect}})),
          idempotency_key: "turn:#{turn.turn_id}")
        if verdict.denied
          Log.warn { "agent turn denied: #{verdict.code}: #{verdict.reason}" }
          return "(turn denied: #{verdict.reason})"
        end
        started = Time.instant
        text = run_rounds(session_key, turn, provider, executor, messages, task_id, event_id, collab_hops)
        # agent.turn.after（observe）：含成功/失败/中断，不再次启动隐式 turn
        after = JSON.parse(JSON.build do |json|
          json.object do
            json.field "agent_id", agent_id_of(session_key)
            json.field "status", text.starts_with?("(provider error") || text.starts_with?("(turn denied") ? "error" : "success"
            json.field "duration_ms", (Time.instant - started).total_milliseconds.to_i64
          end
        end)
        hook_bus.observe("agent.turn.after", hook_context(session_key), after)
        text
      end

      private def run_rounds(session_key : String, turn : TurnContext,
                             provider : Providers::Provider, executor : Tools::Executor,
                             messages : Array(Providers::Message), task_id : String?, event_id : String,
                             collab_hops : Int64? = nil) : String
        (1..MAX_TOOL_ROUNDS).each do |round|
          completion = llm_request(session_key, provider, messages, round)
          unless completion.ok?
            Log.error { "provider error: #{completion.error}" }
            return "(provider error: #{completion.error})"
          end
          # llm.response.transform（§12.11 transform）：可替换文本；宿主再次
          # 解析与校验（ToolCallParser/终答即解析路径不变）
          call = Providers::ToolCallParser.parse(completion.text)
          return finish_round(task_id, round, completion.text) if call.nil?

          # 工具调用轮：执行（衰减面）→ 结果持久化 + 回注 → drain steer →
          # checkpoint → 下一轮。每次调用独立幂等标识：入站事件 + 轮次。
          messages += [Providers::Message.new("assistant", completion.text)]
          # 对话上下文人工在场（unattended=false）：L3 审批走 pending 等人
          # 工，approvals 装配使 fork 的 L3 门可达（M4.2-WP3 fail-closed）。
          round_ctx = Tools::ToolContext.new(session_key, "", "#{event_id}:r#{round}", @store,
            nil, @approvals, false, "deny", collab_hops)
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
        final = llm_request(session_key, provider, messages + [Providers::Message.new("user",
          "tool round limit (#{MAX_TOOL_ROUNDS}) reached; give your final answer now without tool calls.")], MAX_TOOL_ROUNDS)
        final.ok? ? final.text : "(provider error: #{final.error})"
      end

      # llm.request 域三 hook（§12.11）：before（gate+transform——system_append
      # 追加受控 context，model/provider 由宿主固定）、after（observe usage）、
      # error（observe 重试序号）。model/provider/凭据/endpoint 不暴露给插件。
      private def llm_request(session_key : String, provider : Providers::Provider,
                              messages : Array(Providers::Message), attempt : Int32) : Providers::Completion
        request_payload = JSON.parse(%({"provider": #{provider.class.name.split("::").last.inspect}, "model": #{provider.model.inspect}, "message_count": #{messages.size}, "system_append": ""}))
        verdict = hook_bus.gate("llm.request.before", hook_context(session_key), request_payload)
        if verdict.denied
          return Providers::Completion.error("llm hook denied: #{verdict.reason}")
        end
        append_text = verdict.payload.try(&.as_h?).try(&.[]?("system_append")).try(&.as_s?)
        effective = messages
        if append_text && !append_text.empty?
          effective = [Providers::Message.new("system", append_text)] + messages
        end
        started = Time.instant
        completion = provider.complete(effective)
        if completion.ok?
          after = JSON.parse(JSON.build do |json|
            json.object do
              json.field "provider", provider.class.name.split("::").last
              json.field "model", provider.model
              json.field "duration_ms", (Time.instant - started).total_milliseconds.to_i64
              json.field "usage", JSON.parse("{}")
            end
          end)
          hook_bus.observe("llm.request.after", hook_context(session_key), after)
          text = completion.text
          tv = hook_bus.transform("llm.response.transform", hook_context(session_key),
            JSON.parse(%({"provider": #{provider.class.name.split("::").last.inspect}, "model": #{provider.model.inspect}, "text": #{text.inspect}})))
          return Providers::Completion.error("llm hook denied: #{tv.reason}") if tv.denied
          replaced = tv.payload.try(&.as_h?).try(&.[]?("text")).try(&.as_s?)
          replaced ? Providers::Completion.new(replaced, nil) : completion
        else
          err = JSON.parse(JSON.build do |json|
            json.object do
              json.field "provider", provider.class.name.split("::").last
              json.field "attempt", attempt
              json.field "error_code", (completion.error || "error")[0, 64]
            end
          end)
          hook_bus.observe("llm.request.error", hook_context(session_key), err)
          completion
        end
      end

      private def hook_context(session_key : String) : JSON::Any
        JSON.parse(%({"session_key": #{session_key.inspect}}))
      end

      private def agent_id_of(session_key : String) : String
        session_key.split(":")[1]? || ""
      end

      # 终答轮收尾：checkpoint（终答轮也计入 phase）+ 返回终答
      private def finish_round(task_id : String?, round : Int32, text : String) : String
        @store.checkpoint(task_id, round) if task_id
        text
      end
    end
  end
end
