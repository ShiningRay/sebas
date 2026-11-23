require "spec"
require "file_utils"
require "../../../src/platform/store/store"
require "../../../src/platform/store/expectations_store"
require "../../../src/agents/pool"
require "../../../src/providers/providers"
require "../../../src/providers/fake_provider"
require "../../../src/tools/executor"
require "../../../src/orchestration/fork/expectations"
require "../../../src/orchestration/fork/executor"
require "../../../src/orchestration/fork/capability"
require "../../../src/orchestration/fork/snapshot_builder"
require "../../../src/orchestration/fork/join_writer"

module Sebas
  describe "副作用四级 + 冲突处理（M4.2-WP2，semantics §2）" do
    it "内置工具副作用归属：L0 只读两个、L2 共享/网络写两个、L1 file.write" do
      dir = Path[Dir.tempdir, "sebas-se-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir)
      registry = ::Sebas::Tools.default_registry(::Sebas::Channels::Registry.new)
      expect_tool = ->(name : String, side : ::Sebas::Tools::SideEffect) do
        tool = registry.find(name) || raise "missing tool #{name}"
        tool.side_effect.should eq(side)
      end
      expect_tool.call("message.send", ::Sebas::Tools::SideEffect::NetWrite)
      expect_tool.call("memory.save", ::Sebas::Tools::SideEffect::NetWrite)
      expect_tool.call("memory.search", ::Sebas::Tools::SideEffect::ReadOnly)
      expect_tool.call("session.read", ::Sebas::Tools::SideEffect::ReadOnly)
      expect_tool.call("file.write", ::Sebas::Tools::SideEffect::FileWrite)
    end

    it "EffectsLedger：file.write 成功入账（file_write/path），只读工具不入账" do
      dir = Path[Dir.tempdir, "sebas-ledger-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir)
      work = dir / "work.txt"
      registry = ::Sebas::Tools.default_registry(::Sebas::Channels::Registry.new)
      executor = ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new)
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      ledger = ::Sebas::Tools::EffectsLedger.new
      ctx = ::Sebas::Tools::ToolContext.new("agent:main:s:e:p", "acc", "evt-1", store, ledger)

      result = executor.run("file.write", JSON.parse(%({"path": #{work.to_json}, "content": "B"})), ctx)
      result.ok?.should be_true
      File.read(work).should eq("B")
      ledger.entries.size.should eq(1)
      ledger.entries[0].side_effect.should eq("file_write")
      ledger.entries[0].target.should eq(work.to_s)
      ledger.written_paths.should eq([work.to_s])

      # 只读工具执行不入账
      executor.run("session.read", JSON.parse(%({"session": "agent:main:s:e:p"})), ctx)
      ledger.entries.size.should eq(1)
      store.close
    end

    it "冲突场景 e2e：fork 快照指纹 → 成员写文件 → 父期间改同文件 → 回写标 CONFLICT 不自动 merge" do
      dir = Path[Dir.tempdir, "sebas-conflict-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir)
      work = dir / "f.txt"
      File.write(work, "A")

      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      store.create_task("parent-1", "fork_parent")
      expectations = ::Sebas::Orchestration::Fork::Expectations.new(store)
      executor = ::Sebas::Orchestration::Fork::Executor.new(store, expectations,
        -> { ::Sebas::Providers::FakeProvider.new("fake", ["member done"]).as(Providers::Provider) })
      parent_session = "agent:main:internal:main:fork-cli"
      input = ::Sebas::Orchestration::Fork::SnapshotBuilder::Input.new(
        task: "edit file", count: 1, window: nil, include: nil,
        tools: %w[file.write], role: nil, mode: "allSettled", deadline: 3600,
        files: [work.to_s]
      )

      results = executor.run("parent-1", parent_session, "main", "", "", input, ["*"])
      results.size.should eq(1)
      fork_id = results[0].task_id.split(":")[0...2].join(":")

      # 成员副作用：经成员 ledger 执行 file.write 写内容 B（模拟分身工具回路）
      member_session = results[0].session_key
      ledger = executor.member_ledgers[member_session]
      member_ctx = ::Sebas::Tools::ToolContext.new(member_session, "internal", "evt-m",
        store, ledger)
      tools_exec = ::Sebas::Tools::Executor.new(
        ::Sebas::Tools.default_registry(::Sebas::Channels::Registry.new),
        ::Sebas::Channels::Registry.new)
      tools_exec.run("file.write", JSON.parse(%({"path": #{work.to_json}, "content": "B"})), member_ctx)
      ledger.entries.size.should eq(1)
      # 成员副作用落库（可重入 flush——真实链路由工具回路在每次调用后触发）
      executor.flush_member_effects(results)

      # 父期间改同文件（fork 之后、join 回写之前）
      File.write(work, "C")

      # ledger 落库 + join 回写：report 带 effects 与 CONFLICT，文件保持父版本 C
      join_writer = ::Sebas::Orchestration::Fork::JoinWriter.new(store)
      join_writer.write(fork_id).should eq(::Sebas::Orchestration::Fork::JoinWriter::WriteResult::Written)
      report_line = store.transcripts(parent_session).last.content
      report = JSON.parse(report_line)
      report["type"].as_s.should eq("join.report")
      report["effects"].as_a.size.should eq(1)
      report["effects"][0]["tool"].as_s.should eq("file.write")
      conflicts = report["conflicts"].as_a
      conflicts.size.should eq(1)
      conflicts[0]["path"].as_s.should eq(work.to_s)
      conflicts[0]["status"].as_s.should eq("CONFLICT")
      # 不自动 merge：文件内容仍是父写入的 C（join 只报告不合并）
      File.read(work).should eq("C")
      store.close
    end

    it "父在成员写前改同文件、被成员覆盖后仍报 CONFLICT（pre 基线检测）" do
      dir = Path[Dir.tempdir, "sebas-preconflict-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir)
      work = dir / "h.txt"
      File.write(work, "A")

      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      store.create_task("parent-1", "fork_parent")
      expectations = ::Sebas::Orchestration::Fork::Expectations.new(store)
      executor = ::Sebas::Orchestration::Fork::Executor.new(store, expectations,
        -> { ::Sebas::Providers::FakeProvider.new("fake", ["done"]).as(Providers::Provider) })
      parent_session = "agent:main:internal:main:fork-cli"
      input = ::Sebas::Orchestration::Fork::SnapshotBuilder::Input.new(
        task: "edit file", count: 1, window: nil, include: nil,
        tools: %w[file.write], role: nil, mode: "allSettled", deadline: 3600,
        files: [work.to_s]
      )
      results = executor.run("parent-1", parent_session, "main", "", "", input, ["*"])
      fork_id = results[0].task_id.split(":")[0...2].join(":")

      # 父在成员写前改 A→C；成员随后写 B 覆盖 C（post=B 会掩盖父改动）
      File.write(work, "C")
      ledger = executor.member_ledgers[results[0].session_key]
      member_ctx = ::Sebas::Tools::ToolContext.new(results[0].session_key, "internal", "evt-m",
        store, ledger)
      tools_exec = ::Sebas::Tools::Executor.new(
        ::Sebas::Tools.default_registry(::Sebas::Channels::Registry.new),
        ::Sebas::Channels::Registry.new)
      tools_exec.run("file.write", JSON.parse(%({"path": #{work.to_json}, "content": "B"})), member_ctx)
      executor.flush_member_effects(results)

      join_writer = ::Sebas::Orchestration::Fork::JoinWriter.new(store)
      join_writer.write(fork_id)
      report = JSON.parse(store.transcripts(parent_session).last.content)
      conflicts = report["conflicts"].as_a
      conflicts.size.should eq(1)
      conflicts[0]["status"].as_s.should eq("CONFLICT")
      # pre 基线（成员写前现状 C）≠ fork 基线（A）——覆盖被识破
      conflicts[0]["baseline"].as_s.should eq(::Digest::SHA256.hexdigest("B"))
      conflicts[0]["current"].as_s.should eq(::Digest::SHA256.hexdigest("B"))
      store.close
    end

    it "无冲突路径：成员写文件但父未改 → 回写 conflicts 为空" do
      dir = Path[Dir.tempdir, "sebas-noconflict-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir)
      work = dir / "g.txt"
      File.write(work, "A")

      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      store.create_task("parent-1", "fork_parent")
      expectations = ::Sebas::Orchestration::Fork::Expectations.new(store)
      executor = ::Sebas::Orchestration::Fork::Executor.new(store, expectations,
        -> { ::Sebas::Providers::FakeProvider.new("fake", ["done"]).as(Providers::Provider) })
      parent_session = "agent:main:internal:main:fork-cli"
      input = ::Sebas::Orchestration::Fork::SnapshotBuilder::Input.new(
        task: "edit file", count: 1, window: nil, include: nil,
        tools: %w[file.write], role: nil, mode: "allSettled", deadline: 3600,
        files: [work.to_s]
      )
      results = executor.run("parent-1", parent_session, "main", "", "", input, ["*"])
      fork_id = results[0].task_id.split(":")[0...2].join(":")

      # 成员写文件（父不改）→ 无指纹漂移
      ledger = executor.member_ledgers[results[0].session_key]
      member_ctx = ::Sebas::Tools::ToolContext.new(results[0].session_key, "internal", "evt-m",
        store, ledger)
      tools_exec = ::Sebas::Tools::Executor.new(
        ::Sebas::Tools.default_registry(::Sebas::Channels::Registry.new),
        ::Sebas::Channels::Registry.new)
      tools_exec.run("file.write", JSON.parse(%({"path": #{work.to_json}, "content": "B"})), member_ctx)
      executor.flush_member_effects(results)

      join_writer = ::Sebas::Orchestration::Fork::JoinWriter.new(store)
      join_writer.write(fork_id)
      report = JSON.parse(store.transcripts(parent_session).last.content)
      report["conflicts"].as_a.should be_empty
      report["effects"].as_a.size.should eq(1)
      store.close
    end
  end
end
