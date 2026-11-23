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
        # 文件写类在执行前记现状摘要（写前基线，判「父在成员写前已动过」）
        pre_digest = if tool.side_effect == SideEffect::FileWrite &&
                        (target = args.as_h?.try(&.[]?("path")).try(&.as_s?)) && File.file?(target)
                       ::Digest::SHA256.hexdigest(File.read(target))
                     else
                       ""
                     end
        result = tool.run(args, ctx)
        # 副作用台账（M4.2-WP2 §2.2 通则 1「副作用已发生不隐瞒」）：执行成功且
        # 非只读时入账——target 优先取 args.path（文件类），否则 args 摘要。
        # post_digest 用工具随结果返回的实际写入摘要（写入后重读会被并发
        # 改动污染，CodeRabbit PRRT_kwDOVzNPQM664uZR）。
        if result.ok? && (ledger = ctx.ledger) && tool.side_effect != SideEffect::ReadOnly
          target = args.as_h?.try(&.[]?("path")).try(&.as_s?) || Registry.redact(args)[0, 120]
          ledger.record(tool.name, tool.side_effect, target, result.digest || "", pre_digest)
        end
        result
      rescue ex : ::Exception
        # typed rescue 转值：工具错误不炸进程（autobot registry.cr 先例）
        Log.error(exception: ex) { "tool #{name} crashed" }
        ToolResult.error("tool crashed: #{ex.message}")
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
        key = args["session_key"]?.try(&.as_s?) || ctx.session_key
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
