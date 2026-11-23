require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/orchestration/dsl/dsl"
require "../../../src/orchestration/fork/snapshot_builder"
require "../../../src/orchestration/fork/executor"
require "../../../src/orchestration/fork/expectations"
require "../../../src/orchestration/fork/join_writer"

def e2e_env
  dir = Path[Dir.tempdir, "sebas-fork-e2e", "#{Random::Secure.hex(4)}"]
  FileUtils.mkdir_p(dir)
  store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
  ex = ::Sebas::Orchestration::Fork::Expectations.new(store)
  writer = ::Sebas::Orchestration::Fork::JoinWriter.new(store)
  {store, ex, writer}
end

module Sebas
  describe "fork→分身→join 全链 e2e（M4.1-WP5，提案 M1 门槛：一级 fork + 只读分身）" do
    it "DSL 声明 3 分身 → 各自终态 → 按 mode 回写父会话（一级，只读）" do
      store, ex, writer = e2e_env
      store.create_task("parent-1", "fork_parent")
      parent_session = "agent:main:test-acc:email:e2e@example.com"
      5.times { |i| store.append_transcript(parent_session, "user", "ctx-#{i}") }

      executor = ::Sebas::Orchestration::Fork::Executor.new(store, ex,
        -> { ::Sebas::Providers::FakeProvider.new("fake", ["e2e conclusion"]).as(Providers::Provider) }, auto_join_write: false)
      input = ::Sebas::Orchestration::Fork::SnapshotBuilder::Input.new(
        task: "e2e research", count: 3, window: nil, include: nil,
        tools: nil, role: nil, mode: "allSettled", deadline: 3600
      )
      results = executor.run("parent-1", parent_session, "main", "父人格", "", input)

      # 各分身到终态：任务树 kind=fork_child、挂 parent-1、独立会话键
      results.size.should eq(3)
      results.each do |result|
        store.task(result.task_id).kind.should eq("fork_child")
        store.task(result.task_id).parent_id.should eq("parent-1")
        store.task_status?(result.task_id).should eq("done")
      end
      results.uniq(&.session_key).size.should eq(3)
      results.each do |result|
        sk = store.transcripts(result.session_key)
        sk.map(&.role).should eq(["user", "agent"]) # 只读分身：无工具副作用写入
      end

      # 一级 fork：分身工具面无 fork（递归防护在 SnapshotBuilder 身份行声明 + Executor 无派生路径）
      # join 判定 + 三层回写：L1 进父会话
      ex.judge("fork:" + results.first.task_id.split(":")[1]).status.should eq("settled")
      writer.write("fork:" + results.first.task_id.split(":")[1]).should eq(
        ::Sebas::Orchestration::Fork::JoinWriter::WriteResult::Written)
      report = JSON.parse(store.transcripts(parent_session).last.content)
      report["type"].as_s.should eq("join.report")
      report["outcome"].as_s.should eq("settled")
      report["members"].as_a.size.should eq(3)
      # 成员级快照：各分身 user 行含任务描述（快照注入），含父窗口上下文
      sk0 = store.transcripts(results[0].session_key)
      sk0[0].content.should eq("e2e research")
      sk0.size.should eq(2) # user + agent（快照经 provider 消息数组，不落父窗口）
      store.close
    end

    it "KNOWN_TOOLS 含 fork/join（DSL 白名单扩展，#45）" do
      ::Sebas::Orchestration::DSL::Validator::KNOWN_TOOLS.should contain("fork")
      ::Sebas::Orchestration::DSL::Validator::KNOWN_TOOLS.should contain("join")
    end
  end
end
