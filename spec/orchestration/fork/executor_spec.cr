require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/platform/store/expectations_store"
require "../../../src/providers/providers"
require "../../../src/orchestration/fork/expectations"
require "../../../src/orchestration/fork/executor"
require "../../../src/orchestration/fork/snapshot_builder"

def exec_env(max_concurrent : Int32 = 3)
  dir = Path[Dir.tempdir, "sebas-fork-exec-spec", "#{Random::Secure.hex(4)}"]
  FileUtils.mkdir_p(dir)
  store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
  store.create_task("parent-1", "fork_parent")
  expectations = ::Sebas::Orchestration::Fork::Expectations.new(store)
  {store, expectations, dir}
end

# 错误注入 Provider：complete 恒返回 error（成员失败路径用）。
class FailingProvider < ::Sebas::Providers::Provider
  def initialize(model : String = "fake/fail")
    super(model)
  end

  def complete(messages : Array(::Sebas::Providers::Message)) : ::Sebas::Providers::Completion
    ::Sebas::Providers::Completion.new("", "boom")
  end
end

module Sebas
  describe "Fork snapshot + executor (M4.1-WP3)" do
    it "snapshot N=1/N=3：窗口行数正确、system 含 persona+skills、不含 secrets" do
      dir = Path[Dir.tempdir, "sebas-fork-snap-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir)
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      parent_key = "agent:main:test-acc:email:alice@example.com"
      60.times { |i| store.append_transcript(parent_key, "user", "msg-#{i}") }
      input = ::Sebas::Orchestration::Fork::SnapshotBuilder::Input.new(
        task: "parallel research", count: 1, window: 20, include: nil,
        tools: nil, role: nil, mode: "allSettled", deadline: 3600
      )
      frozen = store.transcripts(parent_key)
      messages = ::Sebas::Orchestration::Fork::SnapshotBuilder.build(
        frozen, "parent persona", "## Skills\nskill-text", input, 1
      )
      messages.size.should eq(22) # system + 20 窗口行 + task user
      messages[0].role.should eq("system")
      messages[0].content.should contain("parent persona")
      messages[0].content.should contain("skill-text")
      messages[1].content.should eq("msg-40") # 窗口起点（最近 20 行的第一条）
      messages[-1].content.should eq("parallel research")
      # secrets 不注入：消息数组无 api_key 形态内容
      messages.any?(&.content.matches?(/api_key|secret/)).should be_false
      store.close

      # N=3：窗口 10 行 → 每成员 12 条消息
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      input3 = input.copy_with(window: 10, count: 3)
      frozen = store.transcripts(parent_key)
      [1, 2, 3].each do |member|
        messages = ::Sebas::Orchestration::Fork::SnapshotBuilder.build(
          frozen, "p", "", input3, member
        )
        messages.size.should eq(12)
        messages[0].content.should contain("fork member #{member} of 3")
      end
      store.close

      # assistant 角色转换 + include 白名单 + role 注入
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      store.append_transcript(parent_key, "agent", "prior reply")
      frozen = store.transcripts(parent_key)
      messages = ::Sebas::Orchestration::Fork::SnapshotBuilder.build(
        frozen, "p", "", input3, 1
      )
      agent_msgs = messages.select(&.content.==("prior reply"))
      agent_msgs.size.should eq(1)
      agent_msgs.first.role.should eq("assistant") # agent → assistant 转换
      included = ::Sebas::Orchestration::Fork::SnapshotBuilder.build(
        frozen, "p", "skills-text", input3.copy_with(include: %w[transcripts]), 1
      )
      included[0].content.should contain("fork member") # system 恒有身份行，但无 persona/skills
      included[0].content.should_not contain("skills-text")
      excluded = ::Sebas::Orchestration::Fork::SnapshotBuilder.build(
        frozen, "p", "", input.copy_with(window: 10, count: 1, role: "researcher", include: %w[system_prompt skills]), 1
      )
      excluded.any?(&.content.==("prior reply")).should be_false
      excluded[0].content.should contain("Role card: researcher")
      store.close
      store.close
    end

    it "executor：N=3 全部 done + expectation settled；超并发闸排队不失控" do
      store, expectations, _dir = exec_env
      executor = ::Sebas::Orchestration::Fork::Executor.new(store, expectations,
        -> { ::Sebas::Providers::FakeProvider.new("fake", ["member done"]).as(Providers::Provider) },
        max_concurrent: 2)
      input = ::Sebas::Orchestration::Fork::SnapshotBuilder::Input.new(
        task: "do work", count: 3, window: nil, include: nil,
        tools: nil, role: nil, mode: "allSettled", deadline: 3600
      )
      results = executor.run("parent-1", "agent:main:test-acc:email:p", "main",
        "persona", "", input)
      results.size.should eq(3)
      results.all?(&.state.==("done")).should be_true
      results.uniq(&.session_key).size.should eq(3) # 成员级独立会话键
      # fork_id = task_id 前两段（fork:<短码>）；expectation 已 settle
      fork_id = results.first.task_id.split(":")[0...2].join(":")
      row = store.expectation(fork_id)
      row.status.should eq("settled")
      row.settled_count.should eq(3)
      store.close
    end

    it "provider error：成员 failed 落库，allSettled 恒 settled" do
      store, expectations, _dir = exec_env
      executor = ::Sebas::Orchestration::Fork::Executor.new(store, expectations,
        -> { FailingProvider.new.as(Providers::Provider) })
      input = ::Sebas::Orchestration::Fork::SnapshotBuilder::Input.new(
        task: "t", count: 1, window: nil, include: nil,
        tools: nil, role: nil, mode: "allSettled", deadline: 3600
      )
      results = executor.run("parent-1", "agent:main:test-acc:email:p", "main", "persona", "", input)
      results.first.state.should eq("failed")
      fork_id = results.first.task_id.split(":")[0...2].join(":")
      row = store.expectation(fork_id)
      row.status.should eq("settled")
      row.settled_count.should eq(1)
      store.close
    end
  end
end
