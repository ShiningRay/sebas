# frozen_string_literal: true

require "random"

module Sebas
  module Orchestration
    module Fork
      Log = Sebas::Log.for("sebas.fork")

      # fork/join 原语的装配面（M4.1-WP1）：组件进生产链路，键契约就位。
      #
      # fork 执行体（快照组装→分身 turn）在 M4.1-WP3 落地；expectations 判定
      # 与任务树登记在 M4.1-WP2；本类当前承载的是全部派生契约的**唯一权威**：
      # fork_id 生成、成员会话键、成员 task_id——键口径与
      # docs/design/proposals/fork-join-semantics.md §1.3 逐字对应
      # （成员键 = agent:<父agent_id>:internal:fork:<fork_id>:<member_index>，
      # 成员级独立会话/transcript，是 Join 分层回写按成员记录 session/行数
      # 范围的前提）。
      class ForkManager
        FORK_ID_PREFIX = "fork:"

        getter store : ::Sebas::Platform::Store::Store
        getter registry : ::Sebas::Agents::AgentRegistry
        getter approvals : ::Sebas::Orchestration::Approvals::Center

        def initialize(@store : ::Sebas::Platform::Store::Store,
                       @registry : ::Sebas::Agents::AgentRegistry,
                       @providers : ::Sebas::Providers::Pool,
                       @approvals : ::Sebas::Orchestration::Approvals::Center)
        end

        # 生成一次 fork 调用的 fork_id：`fork:<8 位随机短码>`。
        # fork 级标识（不含成员序号）——expectations.fork_id 与 memo 幂等键
        # `join:<fork_id>:written` 都以它为键；同次 fork 的全部成员共享。
        def new_fork_id : String
          "#{FORK_ID_PREFIX}#{Random::Secure.hex(4)}"
        end

        # 成员会话键：五段结构不动（channel_type 枚举值 "fork"），
        # peer 段 = 完整 fork_id + ":" + member_index（semantics §1.3：peer 段
        # 原样承载 fork_id 不剥前缀，从键反推 fork_id 无需拼装）——与
        # subagent 键先例同构（subagent.cr:44：(agent_id, "internal", "subagent", key)）。
        # 经 Agents.session_key 构造，保证与 Pool 分片 / transcripts 键 /
        # 调度 admission 三处键口径同源。
        def member_session_key(parent_agent_id : String, fork_id : String, member_index : Int) : String
          ::Sebas::Agents.session_key(parent_agent_id, "internal", "fork", member_peer(fork_id, member_index))
        end

        # 成员 task_id：与成员会话键一一对应（join.report members[].task_id /
        # session 由同一 member_index 派生），前缀循 subtask `sub:` 可读先例。
        def member_task_id(fork_id : String, member_index : Int) : String
          "#{fork_id}:#{member_index}"
        end

        # 分身会话键的 peer 段：完整 fork_id + 成员序号。
        private def member_peer(fork_id : String, member_index : Int) : String
          "#{fork_id}:#{member_index}"
        end
      end
    end
  end
end
