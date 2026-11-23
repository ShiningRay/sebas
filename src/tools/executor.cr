require "json"
require "./registry"
require "./file_write"
require "../channels/registry"
require "../platform/store/store"

# 工具执行器（M0-WP6，A6）：注册表查找 → replay 语义门 → 执行 → 错误转值。
# 发消息类工具必须带幂等键（§7.3，Pi §7.5）：崩溃恢复重放不重发。
module Sebas
  module Tools
    class Executor
      Log = Sebas::Log.for("sebas.tools.executor")

      def initialize(@registry : Registry, @channels : Channels::Registry)
      end

      def run(name : String, args : JSON::Any, ctx : ToolContext) : ToolResult
        tool = @registry.find(name)
        return ToolResult.error("unknown tool: #{name}") unless tool
        Log.info { "tool #{name} args=#{Registry.redact(args)} ctx=#{ctx.session_key}" }
        # 文件写类在执行前记现状摘要三态（写前基线，判「父在成员写前已动过」）：
        # 存在=digest；不存在="deleted"（父删过或本就不在——留给 join 结合 fork
        # 基线区分）；非文件类=""（不采集）。
        pre_digest = if tool.side_effect == SideEffect::FileWrite &&
                        (target = args.as_h?.try(&.[]?("path")).try(&.as_s?))
                       File.file?(target) ? ::Digest::SHA256.hexdigest(File.read(target)) : "deleted"
                     else
                       ""
                     end
        deny_result, approval_reason = irreversible_gate?(tool, args, ctx)
        return deny_result if deny_result
        result = tool.run(args, ctx)
        record_side_effect(tool, args, ctx, result, pre_digest, approval_reason)
        result
      rescue ex : ::Exception
        # typed rescue 转值：工具错误不炸进程（autobot registry.cr 先例）
        Log.error(exception: ex) { "tool #{name} crashed" }
        ToolResult.error("tool crashed: #{ex.message}")
      end

      # 副作用台账入账（M4.2-WP2 §2.2 通则 1「副作用已发生不隐瞒」）：执行
      # 成功且非只读时记录——target 优先 args.path（文件类），否则 args 摘要；
      # post_digest 用工具随结果返回的实际写入摘要（写后重读会被并发改动
      # 污染，CodeRabbit PRRT_kwDOVzNPQM664uZR）；L3 审批凭证随清单回写
      # （semantics §7「凭证随 L1 回写」）。
      private def record_side_effect(tool : Tool, args : JSON::Any, ctx : ToolContext,
                                     result : ToolResult, pre_digest : String, approval_reason : String) : Nil
        return unless result.ok?
        ledger = ctx.ledger
        return unless ledger
        return if tool.side_effect == SideEffect::ReadOnly
        target = args.as_h?.try(&.[]?("path")).try(&.as_s?) || Registry.redact(args)[0, 120]
        reason = tool.side_effect == SideEffect::Irreversible ? approval_reason : ""
        ledger.record(tool.name, tool.side_effect, target, result.digest || "", pre_digest, reason)
      end

      # L3 不可逆门（M4.2-WP3 §7「未批不执行 fail-closed」）：返回
      # {deny_result, approval_reason}——deny_result 非 nil 表示拒绝（未批
      # 不执行，调用方原样返回），nil 表示已批准/非 L3 可继续执行；
      # approval_reason 是批准凭证（随副作用清单回写，§7「凭证随 L1 回写」）。
      # 无审批装配一律拒绝（装配为零 = L3 不可达）；有装配走规则链
      # （hardline > off > 无人值守 deny > memo > 超时 deny > 等待人工）。
      private def irreversible_gate?(tool : Tool, args : JSON::Any, ctx : ToolContext) : Tuple(ToolResult?, String)
        return {nil, ""} unless tool.side_effect == SideEffect::Irreversible
        approvals = ctx.approvals
        unless approvals
          return {ToolResult.error("L3 irreversible tool requires an approvals assembly; none wired"), ""}
        end
        decision = approvals.request(tool.name, Registry.redact(args), ctx.session_key,
          unattended: ctx.unattended, mode: ctx.approval_mode)
        unless decision.approved
          return {ToolResult.error("approval denied: #{decision.reason}"), decision.reason}
        end
        Log.info { "L3 approved: #{tool.name} (#{decision.reason})" }
        {nil, decision.reason}
      end
    end

    # 内置工具：发消息（Effectful + 强制幂等键，M0 验收第 3 条）
    class MessageSendTool < Tool
      def initialize(@channels : Channels::Registry)
        super("message.send", "Send a message to a peer via a channel account (requires idempotency_key)",
          ReplaySemantics::Effectful, Risk::High, SideEffect::NetWrite)
      end

      def run(args : JSON::Any, ctx : ToolContext) : ToolResult
        channel = args["channel"]?.try(&.as_s?)
        account = args["account"]?.try(&.as_s?)
        peer = args["peer"]?.try(&.as_s?)
        content = args["content"]?.try(&.as_s?)
        return ToolResult.error("channel/account/peer/content are required") unless channel && peer && content

        adapter = @channels.resolve(channel, account)
        return ToolResult.error("no adapter for #{channel}/#{account || "default"}") unless adapter

        # 幂等键：显式 key 或从事件上下文派生（send:<account_id>:<event_id>，§7.3）
        key = args["idempotency_key"]?.try(&.as_s?) || "send:#{adapter.account_id}:#{ctx.event_id}"
        memo_key = "tool-send:#{key}"
        memo = ctx.store.memo_get(memo_key)
        if memo == "intent"
          # 上次运行在发送中途崩溃——状态未知，保守不重发（fail-closed，Pi §4）
          ToolResult.interrupted("previous send in unknown state (key=#{key})")
        elsif memo && memo.starts_with?("done:")
          ToolResult.success("already delivered (memo=#{memo})") # 重放不重发
        else
          ctx.store.memo_put(memo_key, "intent") if memo.nil? # 先落库再效应（效应三明治）
          deliver(adapter, peer, content, memo_key, ctx)
        end
      end

      private def deliver(adapter : Channels::ChannelAdapter, peer : String, content : String,
                          memo_key : String, ctx : ToolContext) : ToolResult
        result = adapter.send(peer, content)
        if result.ok?
          ctx.store.memo_replace(memo_key, "done:#{result.message_id || "sent"}")
          ToolResult.success("sent via #{adapter.channel_type}/#{adapter.account_id}")
        else
          # 发送失败清意图，允许上层重试（失败可安全重试≠重放重复投递）
          ctx.store.memo_replace(memo_key, "failed:#{result.error}")
          ToolResult.error(result.error || "send failed")
        end
      end
    end

    # 内置工具：记忆检索（Safe，FTS5，§6.2）
    class MemorySearchTool < Tool
      def initialize
        super("memory.search", "Full-text search over indexed memory (FTS5)", ReplaySemantics::Safe, Risk::Low, SideEffect::ReadOnly)
      end

      def run(args : JSON::Any, ctx : ToolContext) : ToolResult
        query = args["query"]?.try(&.as_s?)
        return ToolResult.error("query is required") unless query
        rows = ctx.store.search_memory(query)
        output = rows.map { |row| "[#{row.kind}] #{row.key}: #{row.body[0, 120]}" }.join("\n")
        ToolResult.success(output.empty? ? "(no results)" : output)
      end
    end

    # 内置工具：记忆写入（Effectful but retryable? 整文件写=Safe 口径，§7.3 工具级）
    class MemorySaveTool < Tool
      def initialize
        # 共享写状态（semantics §5.1）：归 L2 走清单回写，不走 L1 文件指纹
        super("memory.save", "Index a memory entry (first-write-wins by key)", ReplaySemantics::Safe, Risk::Medium, SideEffect::NetWrite)
      end

      def run(args : JSON::Any, ctx : ToolContext) : ToolResult
        key = args["key"]?.try(&.as_s?)
        body = args["body"]?.try(&.as_s?)
        kind = args["kind"]?.try(&.as_s?) || "memory"
        return ToolResult.error("key and body are required") unless key && body
        ctx.store.memo_put("memory:#{kind}:#{key}", body) # 决策级幂等：首写为准
        ctx.store.index_memory(kind, key, body)
        ToolResult.success("saved #{kind}/#{key}")
      end
    end

    # 内置工具：会话转录读取（Safe）
    class SessionReadTool < Tool
      def initialize
        super("session.read", "Read recent transcript entries for a session", ReplaySemantics::Safe, Risk::Low, SideEffect::ReadOnly)
      end

      def run(args : JSON::Any, ctx : ToolContext) : ToolResult
        # 越权防护（M4.3-WP1 CodeRabbit）：只可读当前会话——模型提供的
        # session_key 与上下文不符即拒绝（跨会话 transcript 是他人隐私面）
        key = args["session_key"]?.try(&.as_s?) || ctx.session_key
        unless key == ctx.session_key
          return ToolResult.error("session.read 仅可读取当前会话")
        end
        limit = args["limit"]?.try(&.as_i?) || 20
        rows = ctx.store.transcripts(key).last(limit)
        output = rows.map { |row| "[#{row.created_at}] #{row.role}: #{row.content[0, 120]}" }.join("\n")
        ToolResult.success(output.empty? ? "(empty session)" : output)
      end
    end

    # 默认工具面（M0-WP6 交付：发消息/读邮件替代=记忆+会话；M4.2-WP2 增
    # file.write 最小文件写示例，L1 副作用归属与冲突检测的 e2e 载体）
    def self.default_registry(channels : Channels::Registry) : Registry
      registry = Registry.new
      registry.register(MessageSendTool.new(channels))
      registry.register(MemorySearchTool.new)
      registry.register(MemorySaveTool.new)
      registry.register(SessionReadTool.new)
      registry.register(FileWriteTool.new)
      registry
    end
  end
end
