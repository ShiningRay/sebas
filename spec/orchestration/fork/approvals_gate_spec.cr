require "spec"
require "file_utils"
require "../../../src/platform/store/store"
require "../../../src/platform/store/expectations_store"
require "../../../src/agents/pool"
require "../../../src/providers/providers"
require "../../../src/providers/fake_provider"
require "../../../src/tools/executor"
require "../../../src/tools/registry"
require "../../../src/orchestration/approvals/approvals"
require "../../../src/orchestration/fork/executor"
require "../../../src/orchestration/fork/capability"
require "../../../src/orchestration/fork/expectations"
require "../../../src/orchestration/fork/snapshot_builder"
require "../../../src/orchestration/fork/join_writer"

# L3 不可逆示例工具（M4.2-WP3）：仅 spec 用，生产注册表不含 L3 实例
class SpecIrreversibleTool < ::Sebas::Tools::Tool
  def initialize
    super("deploy.prod", "Deploy to production (irreversible)",
      ::Sebas::Tools::ReplaySemantics::Effectful, ::Sebas::Tools::Risk::High,
      ::Sebas::Tools::SideEffect::Irreversible)
  end

  def run(args : JSON::Any, ctx : ::Sebas::Tools::ToolContext) : ::Sebas::Tools::ToolResult
    ::Sebas::Tools::ToolResult.success("deployed")
  end
end

def gate_env
  dir = Path[Dir.tempdir, "sebas-l3gate-spec", Random::Secure.hex(4)]
  FileUtils.mkdir_p(dir)
  store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
  center = ::Sebas::Orchestration::Approvals::Center.new(store)
  registry = ::Sebas::Tools::Registry.new
  registry.register(SpecIrreversibleTool.new)
  executor = ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new)
  ledger = ::Sebas::Tools::EffectsLedger.new
  ctx = ::Sebas::Tools::ToolContext.new("agent:main:s:e:p", "internal", "evt", store,
    ledger, center, true, "deny")
  {store, center, executor, ledger, ctx, dir}
end

module Sebas
  describe "approvals 接线：L3 未批不执行（M4.2-WP3，semantics §7）" do
    it "无人值守 deny：未批不执行、副作用不入账" do
      store, _center, executor, ledger, ctx, _dir = gate_env
      result = executor.run("deploy.prod", JSON.parse(%({"env": "prod"})), ctx)
      result.ok?.should be_false
      result.error.as(String).should contain("unattended run")
      ledger.entries.should be_empty # 未批不执行 = 无副作用
      store.close
    end

    it "hardline 地板：args 含 rm -rf / 直接拒绝（不进规则链后续）" do
      store, _center, executor, _ledger, ctx, _dir = gate_env
      result = executor.run("deploy.prod", JSON.parse(%({"env": "rm -rf /"})), ctx)
      result.ok?.should be_false
      result.error.as(String).should contain("hardline blocklist")
      store.close
    end

    it "无审批装配：L3 直接拒绝（装配为零 = L3 不可达，fail-closed）" do
      dir = Path[Dir.tempdir, "sebas-l3noasm-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir)
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      registry = ::Sebas::Tools::Registry.new
      registry.register(SpecIrreversibleTool.new)
      executor = ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new)
      ctx = ::Sebas::Tools::ToolContext.new("agent:main:s:e:p", "internal", "evt", store)
      result = executor.run("deploy.prod", JSON.parse(%({"env": "prod"})), ctx)
      result.ok?.should be_false
      result.error.as(String).should contain("requires an approvals assembly")
      store.close
    end

    it "批准后执行：审批凭证随副作用清单回写（交互上下文 memo 决策）" do
      store, center, executor, ledger, _ctx, _dir = gate_env
      # 交互上下文（unattended=false）才进 pending 等人工——分身固定
      # unattended=true 走规则③无人值守 deny（恒拒，另一用例覆盖）。
      interactive = ::Sebas::Tools::ToolContext.new("agent:main:s:e:p", "internal", "evt", store,
        ledger, center, false, "deny")
      # memo 预置批准（规则④）：request_id 可由 run_id + tool + args 摘要复现
      args = JSON.parse(%({"env": "prod"}))
      args_summary = ::Sebas::Tools::Registry.redact(args)
      request_id = "approval:agent:main:s:e:p:deploy.prod:#{::Digest::SHA1.hexdigest(args_summary)}"
      store.memo_put("decision:#{request_id}", "approved by operator")

      result = executor.run("deploy.prod", args, interactive)
      result.ok?.should be_true # 批准后执行（memo 决策放行）
      # 审批凭证随副作用清单回写（semantics §7「凭证随 L1 回写」）
      ledger.entries.size.should eq(1)
      ledger.entries[0].approval.as(String).should contain("approved by operator")
      store.close
    end

    it "join.report.effects 携带审批凭证字段（凭证进 L1 回写）" do
      dir = Path[Dir.tempdir, "sebas-l3report-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir)
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      store.create_task("parent-1", "fork_parent")
      expectations = ::Sebas::Orchestration::Fork::Expectations.new(store)
      center = ::Sebas::Orchestration::Approvals::Center.new(store)
      executor = ::Sebas::Orchestration::Fork::Executor.new(store, expectations,
        -> { ::Sebas::Providers::FakeProvider.new("fake", ["done"]).as(Providers::Provider) },
        approvals: center, auto_join_write: false)
      parent_session = "agent:main:internal:main:fork-cli"
      input = ::Sebas::Orchestration::Fork::SnapshotBuilder::Input.new(
        task: "deploy", count: 1, window: nil, include: nil,
        tools: %w[deploy.prod], role: nil, mode: "allSettled", deadline: 3600
      )
      results = executor.run("parent-1", parent_session, "main", "", "", input, ["*"])
      fork_id = results[0].task_id.split(":")[0...2].join(":")

      # member_context 语义断言：分身固定无人值守（L3 自动 deny）+ 装配引用 +
      # 成员台账挂载
      member_ctx = executor.member_context(results[0].session_key)
      member_ctx.unattended.should be_true
      member_ctx.approvals.should eq(center)
      member_ctx.ledger.should_not be_nil

      # 凭证回写链路用交互上下文（unattended=false）+ memo 预置批准（规则④，
      # 不经 spawn 并发——store 非 fiber-safe）：执行 → effects 带凭证 →
      # flush 落 payload → report 聚合
      ledger = executor.member_ledgers[results[0].session_key]
      interactive = ::Sebas::Tools::ToolContext.new(results[0].session_key, "internal", "evt-m",
        store, ledger, center, false, "deny")
      args = JSON.parse(%({"env": "prod"}))
      args_summary = ::Sebas::Tools::Registry.redact(args)
      request_id = "approval:#{results[0].session_key}:deploy.prod:#{::Digest::SHA1.hexdigest(args_summary)}"
      store.memo_put("decision:#{request_id}", "approved by operator")

      tools_exec = ::Sebas::Tools::Executor.new(
        ::Sebas::Tools::Registry.new.tap(&.register(SpecIrreversibleTool.new)),
        ::Sebas::Channels::Registry.new)
      tools_exec.run("deploy.prod", args, interactive)
      executor.flush_member_effects(results)

      executor.flush_member_effects(results)
      join_writer = ::Sebas::Orchestration::Fork::JoinWriter.new(store)
      join_writer.write(fork_id)
      report = JSON.parse(store.transcripts(parent_session).last.content)
      effects = report["effects"].as_a
      effects.size.should eq(1)
      effects[0]["approval"].as_s.should contain("approved by operator")
      store.close
    end
  end
end
