require "json"
require "../../plugins/hook_bus"

# 会话压缩接口与协议（M3-WP5，#17；design.md §12.11 session.compact.*）。
#
# WBS 口径（M3-WP5 依赖节）：会话压缩若实现时仍无生产压缩器，先交付明确
# 的 SessionCompactor 接口与协议完整实现，不能用假 hook 声称完成生产压缩。
#
# 本文件交付：
# - `SessionCompactor` 接口：会话转写 → 摘要 + 计数（生产压缩器后续包实现）；
# - `CompactionRunner` 协议：compact.before（observe，压缩任务开始时只读）
#   → 委托 compactor → 成功提交后 compact.after（带计数与摘要元数据）；
#   失败/取消不触发 after（§12.11 统一执行规则）。observe 异常按隔离口径
#   跳过，不阻塞压缩主流程。
#
# 首版无生产压缩器：调用方持 runner 与接口即可装配后续实现；本包不注册
# 任何自动压缩调度（插件不自建循环，§12.11）。
module Sebas
  module Sessions
    module Compaction
      # 摘要元数据（§12.11 compact.after payload 契约：session_key/
      # summary_tokens/summary）
      record CompactionResult, summary : String, summary_tokens : Int32, dropped_count : Int32

      abstract class SessionCompactor
        # 压缩一个会话的转写：实现方负责摘要生成与转写提交；失败抛异常
        # （runner 据此跳过 compact.after）。
        abstract def compact(session_key : String, transcript : Array(String)) : CompactionResult
      end

      class CompactionRunner
        getter hook_bus : ::Sebas::Plugins::HookBus

        def initialize(@hook_bus : ::Sebas::Plugins::HookBus = ::Sebas::Plugins::HookBus.disabled)
        end

        # 压缩一个会话：before（observe）→ compactor → after（observe，仅成功）。
        # 失败向上抛（调用方决定重试/放弃），不伪报成功。
        def run(compactor : SessionCompactor, session_key : String,
                transcript : Array(String)) : CompactionResult
          hook_bus.observe("session.compact.before", JSON.parse("{}"),
            JSON.parse(%({"session_key": #{session_key.inspect}})))
          result = compactor.compact(session_key, transcript)
          hook_bus.observe("session.compact.after", JSON.parse("{}"),
            JSON.parse(JSON.build do |json|
              json.object do
                json.field "session_key", session_key
                json.field "summary_tokens", result.summary_tokens
                json.field "summary", result.summary[0, 400]
              end
            end), idempotency_key: "compact:#{session_key}")
          result
        end
      end
    end
  end
end
