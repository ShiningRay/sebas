require "json"
require "../platform/store/store"
require "../channels/base"
require "../orchestration/approvals/approvals"

# 工具注册表（M0-WP6，A9 升级）：replay/risk 为类型级字段（design.md §7.3/§10.3）；
# 决策级幂等走 memo（first-write-wins）；日志全程脱敏（A9）。
module Sebas
  module Tools
    Log = Sebas::Log.for("sebas.tools")

    # 重放语义（Pi §4 二分）：只读/整文件写=Safe 可重跑；未标注一律 Effectful 不重跑
    enum ReplaySemantics
      Safe
      Effectful
    end

    # 风险级别（§10.3 审批链分层；M0 不接审批，M2-WP4 消费）
    enum Risk
      Low
      Medium
      High
    end

    # 副作用四级（M4.2-WP2，semantics §2.1 Q6 矩阵行维度）：join 回写策略
    # 按成员执行期间发生过的最高级别选格——L0 只读结论直并；L1 文件写触发
    # 指纹冲突检测；L2 共享/网络写清单回写（幂等键防重复）；L3 不可逆叠加
    # §7 审批链（M2-WP4 接）。与 Risk（审批分层）正交：两维度独立声明。
    enum SideEffect
      ReadOnly
      FileWrite
      NetWrite
      Irreversible
    end

    # 单条副作用记录（semantics §2.2 矩阵通则 1「副作用已发生不隐瞒」）：
    # 工具名 + 副作用级 + 目标（文件路径 / 会话键 / 内容摘要）+ 时间。
    record Effect, tool : String, side_effect : String, target : String, at : String,
      post_digest : String = "", pre_digest : String = "", approval : String = "" do
      def to_json_object : Hash(String, JSON::Any)
        {
          "tool"        => JSON::Any.new(tool),
          "side_effect" => JSON::Any.new(side_effect),
          "target"      => JSON::Any.new(target),
          "at"          => JSON::Any.new(at),
          "post_digest" => JSON::Any.new(post_digest),
          "pre_digest"  => JSON::Any.new(pre_digest),
          # L3 不可逆的审批凭证（decision reason，semantics §7「凭证随 L1 回写」）
          "approval" => JSON::Any.new(approval),
        }
      end
    end

    # 副作用台账（M4.2-WP2）：成员执行期间经由 ToolContext.ledger 收集，
    # join 回写时并入 join.report.effects（只读工具不入账）。
    class EffectsLedger
      getter entries : Array(Effect)

      def initialize
        @entries = [] of Effect
      end

      def record(tool : String, side_effect : SideEffect, target : String,
                 post_digest : String = "", pre_digest : String = "",
                 approval : String = "") : Nil
        @entries << Effect.new(tool, side_effect.to_s.underscore, target,
          ::Time.utc.to_rfc3339, post_digest, pre_digest, approval)
      end

      # 各路径成员写前现状摘要（该路径最新一条 file_write 条目）——配合 fork
      # 基线检测「父在成员写前已改动/创建」的漂移（会被成员写覆盖掩盖）。
      def written_pre_digests : Hash(String, String)
        @entries.select { |e| e.side_effect == "file_write" && !e.pre_digest.empty? }
          .each_with_object(Hash(String, String).new) do |e, hash|
            hash[e.target] = e.pre_digest
          end
      end

      # L1 文件写涉及的路径集（指纹冲突检测的对比清单）
      def written_paths : Array(String)
        paths = @entries.select { |e| e.side_effect == "file_write" }.map(&.target)
        paths.uniq!
      end

      # 各路径成员写后的内容摘要（该路径最新一条 file_write 条目）——
      # 冲突检测基线：成员写后状态 vs 回写时现状（semantics §2.2 L1）。
      def written_digests : Hash(String, String)
        @entries.select { |e| e.side_effect == "file_write" && !e.post_digest.empty? }
          .each_with_object(Hash(String, String).new) do |e, hash|
            hash[e.target] = e.post_digest
          end
      end
    end

    record ToolResult, ok : Bool, output : String, error : String?, digest : String? = nil do
      # digest（M4.2-WP2）：文件写类工具随结果返回实际写入内容的摘要——
      # 冲突检测基线必须对应写入字节，写入后重读会被并发改动污染。
      def self.success(output : String, digest : String? = nil) : ToolResult
        new(true, output, nil, digest)
      end

      def ok? : Bool
        ok
      end

      def self.error(message : String) : ToolResult
        new(false, "", message)
      end

      # 上次运行被中断、状态未知——不重跑，交上层决策（fail-closed）
      def self.interrupted(message : String) : ToolResult
        new(false, "", "interrupted: #{message}")
      end
    end

    # 工具运行上下文：会话/账号维度 + 持久层句柄（scope 由构造器保证，Hermes contextvar 教训反面）。
    # ledger（M4.2-WP2）：副作用台账可选挂载——nil 时 effectful 工具执行
    # 只返回结果不入账（非分身调用路径行为不变）。
    # approvals/unattended/approval_mode（M4.2-WP3 §7）：L3 不可逆工具执行前
    # 必经 Approvals::Center.request（未批不执行 fail-closed）；unattended
    # 默认 true（无人值守 deny），分身上下文固定 true，父 agent 交互路径可 false。
    record ToolContext,
      session_key : String,
      account_id : String,
      event_id : String,
      store : Platform::Store::Store,
      ledger : EffectsLedger? = nil,
      approvals : ::Sebas::Orchestration::Approvals::Center? = nil,
      unattended : Bool = true,
      approval_mode : String = "deny",
      # 协作 turn 的链路跳数（#186）：绑定启动本 turn 的 delivery——message_agent
      # 缺省 hops 取此值而非会话 memo（同会话多链路并发时 memo 会被新链覆盖）
      collab_hops : Int64? = nil

    abstract class Tool
      getter name : String
      getter description : String
      getter replay : ReplaySemantics
      getter risk : Risk
      # 副作用四级归属（M4.2-WP2 §2.1）：默认只读——写类工具显式声明，
      # 防新增工具漏标静默按只读处理。
      getter side_effect : SideEffect

      def initialize(@name : String, @description : String, @replay : ReplaySemantics, @risk : Risk,
                     @side_effect : SideEffect = SideEffect::ReadOnly)
      end

      abstract def run(args : JSON::Any, ctx : ToolContext) : ToolResult

      # 副作用自记账声明（M4.2-WP2 CodeRabbit）：默认 false——Executor 通用
      # 记账覆盖；实际写入路径只有工具自身可知时（如 file.write 的 base_dir
      # 解析）覆写为 true 并自行入账（Executor 跳过防重复/错路径）。
      def self_records_effects? : Bool
        false
      end
    end

    class Registry
      @tools = Hash(String, Tool).new
      @mutex = Mutex.new

      def register(tool : Tool) : Nil
        @mutex.synchronize { @tools[tool.name] = tool }
      end

      # 衰减过滤用（M4.3-WP1）：移除白名单外工具
      def unregister(name : String) : Nil
        @mutex.synchronize { @tools.delete(name) }
      end

      # 白名单裁剪（M4.3-WP1 / #185 WP1）：allowed 含 "*" = 全量（现状口径），
      # 否则白名单外工具整体移除——工具面即生效面；装配侧与 spec 共用同一口径。
      def restrict_to(allowed : Array(String)) : Nil
        return if allowed.includes?("*")
        names.each do |name|
          unregister(name) unless allowed.includes?(name)
        end
      end

      def find(name : String) : Tool?
        @mutex.synchronize { @tools[name]? }
      end

      def names : Array(String)
        @mutex.synchronize { @tools.keys }
      end

      # 工具面描述（进 agent system prompt；M0-WP6b skills 同款输出格式）
      def describe : String
        @mutex.synchronize do
          @tools.values.map { |tool| "- #{tool.name} (risk:#{tool.risk} replay:#{tool.replay}): #{tool.description}" }.join("\n")
        end
      end

      # 日志脱敏（A9）：args 中的敏感字段值替换为 [REDACTED]
      def self.redact(args : JSON::Any) : String
        obj = args.as_h?
        return args.to_s unless obj
        cleaned = obj.map do |key, value|
          value = JSON::Any.new("[REDACTED]") if SENSITIVE_KEYS.includes?(key.downcase)
          {key, value}
        end.to_h
        JSON::Any.new(cleaned).to_json
      rescue ::Exception
        "[UNPARSABLE]"
      end

      SENSITIVE_KEYS = %w[password secret token api_key refresh_token]
    end
  end
end
