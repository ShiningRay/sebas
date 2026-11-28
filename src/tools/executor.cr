require "json"
require "./registry"
require "./file_write"
require "../channels/registry"
require "../platform/store/store"
require "../plugins/hook_bus"

# 工具执行器（M0-WP6，A6）：注册表查找 → replay 语义门 → 执行 → 错误转值。
# 发消息类工具必须带幂等键（§7.3，Pi §7.5）：崩溃恢复重放不重发。
module Sebas
  module Tools
    class Executor
      Log = Sebas::Log.for("tools.executor")

      # hook_before 返回结构：denied=true 表示拒绝执行（reason 携带结构化
      # 原因），args 为替换后（或原样）参数
      record HookBefore, denied : Bool, args : JSON::Any, reason : String

      # hook 门面（M3-WP5，#17）：未装配 = disabled，注入点零开销直通
      setter hook_bus : ::Sebas::Plugins::HookBus

      def initialize(@registry : Registry, @channels : Channels::Registry,
                     hook_bus : ::Sebas::Plugins::HookBus = ::Sebas::Plugins::HookBus.disabled)
        @hook_bus = hook_bus
      end

      # 工具域三 hook（§12.11）：call.before（gate+transform，deny 拒执行、
      # params 替换过重校验）→ 执行 → call.after（observe，失败隔离）→
      # result.transform（替换 output 文本；deny fail-closed 转错误结果）。
      # hook 异常绝不逃出 run——注入点自身按 observe 隔离口径兜底。
      def run(name : String, args : JSON::Any, ctx : ToolContext) : ToolResult
        tool = @registry.find(name)
        return ToolResult.error("unknown tool: #{name}") unless tool
        Log.info { "tool #{name} args=#{Registry.redact(args)} ctx=#{ctx.session_key}" }
        hooked = hook_before(tool, args, ctx)
        return ToolResult.error("tool hook denied: #{hooked.reason}") if hooked.denied
        args = hooked.args
        deny_result, approval_reason = irreversible_gate?(tool, args, ctx)
        return deny_result if deny_result
        tool_started = Time.instant
        result = begin
          tool.run(args, ctx)
        rescue ex : ::Exception
          # 异常就地转值（M3-WP5 review）：转结构化结果后仍走公共 after 通知
          # 路径——订阅者收到 exception 终态；错误返回口径不变
          Log.error(exception: ex) { "tool #{name} crashed" }
          ToolResult.error("tool crashed: #{ex.message}")
        end
        tool_duration_ms = (Time.instant - tool_started).total_milliseconds.to_i64
        record_side_effect(tool, args, ctx, result, approval_reason)
        result = hook_result(tool, ctx, result)
        hook_after(tool, ctx, result, tool_duration_ms)
        result
      rescue ex : ::Exception
        # typed rescue 转值：工具错误不炸进程（autobot registry.cr 先例）
        Log.error(exception: ex) { "tool #{name} crashed" }
        ToolResult.error("tool crashed: #{ex.message}")
      end

      # tool.call.before（gate+transform，§12.11）：deny（显式/异常/非法
      # payload，fail-closed）→ args nil；替换 params 已在 dispatcher 重过
      # payload schema。
      private def hook_before(tool : Tool, args : JSON::Any, ctx : ToolContext) : HookBefore
        payload = tool_payload(tool.name, args, ctx)
        # transform 派发（M3-WP5 review）：tool.call.before 是 GateTransform——
        # gate 的 interpret 对裸返回值不替换，DSL modify! 会被丢弃；transform
        # 路径 deny 短路与替换重校验同源
        verdict = @hook_bus.transform("tool.call.before", hook_context(ctx), payload)
        if verdict.denied
          return HookBefore.new(true, args, "#{verdict.code}: #{verdict.reason}")
        end
        replaced = verdict.payload.try(&.as_h?).try(&.[]?("params"))
        HookBefore.new(false, replaced || args, "")
      rescue ex
        Log.warn { "tool.call.before hook failed for #{tool.name}: #{ex.message} (deny fail-closed)" }
        HookBefore.new(true, args, "hook_failed: #{(ex.message || "hook failed")[0, 200]}")
      end

      private def hook_after(tool : Tool, ctx : ToolContext, result : ToolResult, duration_ms : Int64) : Nil
        status = result.ok? ? "success" : (result.error.to_s.includes?("crashed") ? "exception" : "error")
        # result_summary 不含正文（M3-WP5 review，CWE-200）：tool.call.after 非
        # sensitive，摘要只承载非正文状态（digest/状态词）——输出/异常文本留在
        # 宿主日志与账本，插件读正文须走敏感批准面
        summary = if result.ok?
                    result.digest ? "digest:#{result.digest}" : "ok"
                  elsif status == "exception"
                    "exception"
                  else
                    "error"
                  end
        payload = JSON.parse(JSON.build do |json|
          json.object do
            json.field "tool_id", tool.name
            json.field "request_id", ctx.event_id
            json.field "session_key", ctx.session_key
            json.field "status", status
            json.field "duration_ms", duration_ms
            json.field "result_summary", summary
          end
        end)
        @hook_bus.observe("tool.call.after", hook_context(ctx), payload)
      rescue ex
        Log.warn { "tool.call.after hook skipped for #{tool.name}: #{ex.message} (observe isolation)" }
      end

      # result.transform（§12.11「可替换受限文本结果」）：仅替换成功结果的
      # output 文本；deny fail-closed 转错误结果，不返回未校验的文本。
      private def hook_result(tool : Tool, ctx : ToolContext, result : ToolResult) : ToolResult
        return result unless result.ok?
        payload = JSON.parse(%({"tool_id": #{tool.name.to_json}, "request_id": #{ctx.event_id.to_json}, "text": #{result.output.to_json}}))
        verdict = @hook_bus.transform("tool.result.transform", hook_context(ctx), payload)
        return ToolResult.error("result transform denied: #{verdict.reason}") if verdict.denied
        replaced = verdict.payload.try(&.as_h?).try(&.[]?("text")).try(&.as_s?)
        replaced ? ToolResult.success(replaced, result.digest) : result
      rescue ex
        Log.warn { "tool.result.transform hook failed for #{tool.name}: #{ex.message} (deny fail-closed)" }
        ToolResult.error("result transform failed: #{ex.message}")
      end

      private def tool_payload(tool_id : String, args : JSON::Any, ctx : ToolContext) : JSON::Any
        JSON.parse(%({"tool_id": #{tool_id.to_json},"request_id": #{ctx.event_id.to_json},"session_key": #{ctx.session_key.to_json},"params": #{args.to_json}}))
      end

      private def hook_context(ctx : ToolContext) : JSON::Any
        JSON.parse(%({"session_key": #{ctx.session_key.to_json}, "account_id": #{ctx.account_id.to_json}}))
      end

      # 副作用台账入账（M4.2-WP2 §2.2 通则 1「副作用已发生不隐瞒」）：执行
      # 成功且非只读时记录——target 优先 args.path（文件类），否则 args 摘要；
      # post_digest 用工具随结果返回的实际写入摘要（写后重读会被并发改动
      # 污染，CodeRabbit PRRT_kwDOVzNPQM664uZR）；L3 审批凭证随清单回写
      # （semantics §7「凭证随 L1 回写」）。
      private def record_side_effect(tool : Tool, args : JSON::Any, ctx : ToolContext,
                                     result : ToolResult, approval_reason : String) : Nil
        return unless result.ok?
        ledger = ctx.ledger
        return unless ledger
        return if tool.side_effect == SideEffect::ReadOnly
        return if tool.self_records_effects? # 自记账工具（file.write）自理路径与摘要
        target = args.as_h?.try(&.[]?("path")).try(&.as_s?) || Registry.redact(args)[0, 120]
        reason = tool.side_effect == SideEffect::Irreversible ? approval_reason : ""
        ledger.record(tool.name, tool.side_effect, target, result.digest || "", "", reason)
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
      # hook 门面（M3-WP5，#17）：gateway 装配后注入；缺省 disabled 零开销
      property hook_bus : ::Sebas::Plugins::HookBus = ::Sebas::Plugins::HookBus.disabled

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
        elsif memo == "failed:hook_denied"
          # gate deny 终态（M3-WP5 review）：dispatcher 的 gate memo 仅进程
          # 内存级，重启后重试若重新过 gate，插件改判放行会发出被拒消息——
          # 持久 memo 直接短路，同 key 重试不重投递
          ToolResult.interrupted("message hook denied (recorded; key=#{key})")
        elsif memo && memo.starts_with?("done:")
          ToolResult.success("already delivered (memo=#{memo})") # 重放不重发
        else
          ctx.store.memo_put(memo_key, "intent") if memo.nil? # 先落库再效应（效应三明治）
          deliver(adapter, peer, content, memo_key, ctx)
        end
      end

      private def deliver(adapter : Channels::ChannelAdapter, peer : String, content : String,
                          memo_key : String, ctx : ToolContext) : ToolResult
        # message.sending（M3-WP5，#17 §12.11 gate+transform）：可 deny/修改
        # 文本与附件元数据；不得替换账号/收件人（payload 只读键）。
        # idempotency_key 用 send memo 键——投递重放时裁决随之复用。
        payload = JSON.parse(JSON.build do |json|
          json.object do
            json.field "channel", adapter.channel_type
            json.field "account_id", adapter.account_id
            json.field "peer", peer
            json.field "content", content
            json.field "attachments", [] of String
          end
        end)
        # transform 派发（M3-WP5 review）：message.sending 是 GateTransform，
        # DSL modify! 的替换经重校验生效（同 tool.call.before 口径）
        verdict = hook_bus.transform("message.sending", JSON.parse("{}"), payload, idempotency_key: memo_key)
        if verdict.denied
          # deny 写非 intent 终态：run 层按持久 memo 短路（同 key 重试不再过
          # gate 投递）；dispatcher 的同 key deny memo 只在进程内生效——重启
          # 后由 run 的 failed:hook_denied 短路兜底（M3-WP5 review）
          ctx.store.memo_replace(memo_key, "failed:hook_denied")
          return ToolResult.interrupted("message hook denied: #{verdict.code}: #{verdict.reason}")
        end
        replaced = verdict.payload.try(&.as_h?).try(&.[]?("content")).try(&.as_s?)
        result = adapter.send(peer, replaced || content)
        if result.ok?
          ctx.store.memo_replace(memo_key, "done:#{result.message_id || "sent"}")
        else
          # 发送失败清意图，允许上层重试（失败可安全重试≠重放重复投递）
          ctx.store.memo_replace(memo_key, "failed:#{result.error}")
        end
        # message.sent（observe）：memo 落库后再通知（M3-WP5 review）——慢插件
        # 不拖延记账，崩溃窗口不留「intent 态已送达」误判；observe 隔离，
        # 不改投递结果
        sent = JSON.parse(JSON.build do |json|
          json.object do
            json.field "status", result.ok? ? "success" : "error"
            json.field "message_id", result.message_id
            json.field "error_code", result.ok? ? nil : (result.error || "send_failed")[0, 64]
          end
        end)
        begin
          hook_bus.observe("message.sent", JSON.parse("{}"), sent)
        rescue ex
          Log.warn { "message.sent hook skipped: #{ex.message} (observe isolation)" }
        end
        result.ok? ? ToolResult.success("sent via #{adapter.channel_type}/#{adapter.account_id}") : ToolResult.error(result.error || "send failed")
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
