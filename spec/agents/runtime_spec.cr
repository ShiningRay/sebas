require "spec"
require "file_utils"
require "../../src/platform/store/store"
require "../../src/agents/runtime"
require "../../src/providers/fake_provider"

# 脚本化 Provider：按调用次序返回预设响应（记录每轮请求消息序）
class RuntimeScriptedProvider < ::Sebas::Providers::Provider
  @scripts : Array(String)
  @count = 0
  getter seen_messages : Array(Array(::Sebas::Providers::Message))

  def initialize(model : String, scripts : Array(String))
    super(model)
    @scripts = scripts
    @seen_messages = [] of Array(::Sebas::Providers::Message)
  end

  def complete(messages : Array(::Sebas::Providers::Message)) : ::Sebas::Providers::Completion
    @seen_messages << messages
    idx = @count
    @count += 1
    ::Sebas::Providers::Completion.new(@scripts[idx]? || "script exhausted", nil)
  end
end

module Sebas
  describe "AgentRuntime（M4.5-WP4）" do
    it "循环顺序固定：模型响应 → 工具调用 → 结果落库 → drain steer 注入 → 下一次模型调用" do
      dir = Path[Dir.tempdir, "sebas-runtime-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir)
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      provider = RuntimeScriptedProvider.new("fake/runtime", [
        # 第一轮：发起工具调用
        "checking\n```json\n{\"tool\": \"memory.save\", \"args\": {\"key\": \"rt\", \"body\": \"r1\"}}\n```",
        # 第二轮：终答
        "final answer",
      ])
      drain_calls = [] of Tuple(String, String, Int64)
      drain = ->(session : String, turn_id : String, generation : Int64) do
        drain_calls << {session, turn_id, generation}
        ["[steer s1] mid-turn correction"] of String
      end
      runtime = ::Sebas::Agents::AgentRuntime.new(store, nil, drain)
      turn = ::Sebas::Agents::TurnContext.new("agent:main:acc:email:rt@example.com", "turn:e1", 1_i64)
      messages = [::Sebas::Providers::Message.new("system", "sys")] +
                 [::Sebas::Providers::Message.new("user", "hello")]

      channels = ::Sebas::Channels::Registry.new
      executor = ::Sebas::Tools::Executor.new(::Sebas::Tools.default_registry(channels), channels)
      task = store.create_task("turn:e1", "turn", payload: "")
      reply = runtime.run(turn.session_key, turn, provider, executor, messages, task.id, "e1")

      reply.should eq("final answer")
      # drain 只在有工具调用的轮发生（固定顺序：工具结果落库后注入）；
      # 终答轮无工具结果无 drain 点——无工具边界 turn 结束由 flush 收口
      drain_calls.size.should eq(1)
      drain_calls.first.should eq({turn.session_key, "turn:e1", 1_i64})

      # 注入时序：第二轮请求里工具结果之后才是 steer 消息（固定顺序证明）
      second_round = provider.seen_messages[1]
      texts = second_round.map(&.content)
      tool_idx = texts.index(&.starts_with?("tool result (memory.save)")).should_not be_nil
      steer_idx = texts.index(&.starts_with?("[steer s1]")).should_not be_nil
      tool_idx.as(Int32).should be < steer_idx.as(Int32)
      # steer 在 assistant 工具调用消息之后
      asst_idx = texts.index("checking\n```json\n{\"tool\": \"memory.save\", \"args\": {\"key\": \"rt\", \"body\": \"r1\"}}\n```").should_not be_nil
      asst_idx.as(Int32).should be < steer_idx.as(Int32)
      store.close
    end

    it "steer 未装配（drain nil）：行为与 WP4 之前一致，不注入" do
      dir = Path[Dir.tempdir, "sebas-runtime-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir)
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      provider = RuntimeScriptedProvider.new("fake/runtime", ["plain answer"])
      runtime = ::Sebas::Agents::AgentRuntime.new(store, nil, nil)
      turn = ::Sebas::Agents::TurnContext.new("agent:main:acc:email:rt2@example.com", "turn:e2", 1_i64)
      channels = ::Sebas::Channels::Registry.new
      executor = ::Sebas::Tools::Executor.new(::Sebas::Tools.default_registry(channels), channels)
      reply = runtime.run(turn.session_key, turn, provider, executor,
        [::Sebas::Providers::Message.new("user", "hi")], nil, "e2")
      reply.should eq("plain answer")
      store.close
    end
  end
end
