# frozen_string_literal: true

module Sebas
  module Orchestration
    module Fork
      # join 三层回写的装配面（M4.1-WP1）。
      #
      # 回写本体（L1 结论进父会话 / L2 引用分身会话 / L3 检索三元组）与
      # 四时机语义在 M4.1-WP4 落地；本类当前承载回写幂等契约的唯一权威：
      # memo 键 `join:<fork_id>:written`（semantics §3——先写后发、
      # first-write-wins 先例 store.cr:369-383，崩溃重放不重复回写）。
      class JoinWriter
        getter store : ::Sebas::Platform::Store::Store

        def initialize(@store : ::Sebas::Platform::Store::Store)
        end

        # 回写幂等 memo 键：fork 级标识（不含成员序号）——同次 fork 一条
        # 回写记录，全成员共用同一幂等闸。
        def memo_key(fork_id : String) : String
          "join:#{fork_id}:written"
        end

        # 已回写过？（memo 决策先例：memo_get 非 nil 即已写）
        def written?(fork_id : String) : Bool
          !@store.memo_get(memo_key(fork_id)).nil?
        end
      end
    end
  end
end
