require "spec"
require "file_utils"
require "../../src/agents/agents"
require "../../src/agents/subagent"
require "../../src/orchestration/collaboration/collaboration"
require "../../src/tools/executor"
require "../../src/platform/store/store"

def m3_tmp_store
  dir = Path[ENV["TEMP"], "sebas-m3-spec", Random::Secure.hex(4)]
  FileUtils.rm_rf(dir)
  ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
end

def m3_agents_dir
  dir = Path[ENV["TEMP"], "sebas-m3-spec", "agents-#{Random::Secure.hex(4)}"]
  FileUtils.rm_rf(dir)
  Dir.mkdir_p(dir)
  dir
end

def wait_for(seconds : Time::Span = 5.seconds, &condition : -> Bool) : Bool
  deadline = Time.instant + seconds
  until Time.instant > deadline
    return true if condition.call
    sleep 20.milliseconds
  end
  condition.call
end

module Sebas
  describe "collaboration + subagents (M3-WP1/2/3)" do
    it "keeps two agents with independent personas and memory (WP1 验收)" do
      registry = ::Sebas::Agents::AgentRegistry.new(m3_agents_dir)
      work = registry.get_or_create("work", persona: "# Work agent\nProfessional tone.")
      home = registry.get_or_create("home", persona: "# Home agent\nCasual tone.")
      work.persona.should contain("Professional")
      home.persona.should contain("Casual")

      work.memory_write("MEMORY.md", "work memory entry")
      home.memory_write("MEMORY.md", "home memory entry")
      work.memory_read("MEMORY.md").should eq("work memory entry") # 记忆隔离
      home.memory_read("MEMORY.md").should eq("home memory entry")
      registry.size.should eq(2)
      registry.ids.sort.should eq(["home", "work"])
    end

    it "signs agent messages and delivers fire-and-forget (WP2 署名)" do
      store = m3_tmp_store
      registry = ::Sebas::Agents::AgentRegistry.new(m3_agents_dir)
      registry.get_or_create("alice")
      registry.get_or_create("bob")
      messenger = ::Sebas::Orchestration::Collaboration::Messenger.new(registry, store)

      message = messenger.send_message("alice", "bob", "please summarize")
      message = message.should_not be_nil
      message.delivery_id.should contain("dm:")
      message.content.should contain("Message from 🤖 alice: please summarize")
      message.hops.should eq(1)

      received = messenger.receive?(2.seconds).should_not be_nil
      received.to_agent.should eq("bob")
      messenger.delivered_to("bob").size.should eq(1)
      store.close
    end

    it "blocks agent ping-pong at max_hops=4 (§14 M3 验收第 1 条)" do
      store = m3_tmp_store
      registry = ::Sebas::Agents::AgentRegistry.new(m3_agents_dir)
      registry.get_or_create("a")
      registry.get_or_create("b")
      messenger = ::Sebas::Orchestration::Collaboration::Messenger.new(registry, store, max_hops: 4)

      # 互回链路：hop 1→4 可发，第 5 跳拒发（LoopGuardExceeded）
      hops_ok = 0
      error = nil
      5.times do |i|
        from = i.even? ? "a" : "b"
        to = i.even? ? "b" : "a"
        begin
          messenger.send_message(from, to, "ping #{i}", hops: i.to_i64)
          hops_ok += 1
        rescue ex : ::Sebas::Orchestration::Collaboration::LoopGuardExceeded
          error = ex
          break
        end
      end
      hops_ok.should eq(4) # hop 1..4 通过
      raised = error.nil? ? ::Sebas::Orchestration::Collaboration::LoopGuardExceeded.new("x") : error
      raised = raised.as(::Sebas::Orchestration::Collaboration::LoopGuardExceeded)
      raised.message.to_s.should contain("max_hops=4")
      store.close
    end

    it "message_agent tool reports loop-guard errors as values" do
      store = m3_tmp_store
      registry = ::Sebas::Agents::AgentRegistry.new(m3_agents_dir)
      registry.get_or_create("looped")
      messenger = ::Sebas::Orchestration::Collaboration::Messenger.new(registry, store, max_hops: 2)
      tool = ::Sebas::Orchestration::Collaboration::MessageAgentTool.new(messenger)
      store2 = m3_tmp_store
      ctx = ::Sebas::Tools::ToolContext.new("agent:looped:internal:collaboration:x", "internal", "evt", store2)

      result = tool.run(::JSON.parse(%({"agent": "looped", "content": "hi", "hops": 2})), ctx)
      result.ok?.should be_false
      result.error.to_s.should contain("max_hops=2")
      store.close
      store2.close
    end

    it "caps subagent concurrency at the semaphore limit (§14 M3 验收 并发上限)" do
      store = m3_tmp_store
      registry = ::Sebas::Agents::AgentRegistry.new(m3_agents_dir)
      inflight = 0
      peak = 0
      mutex = Mutex.new
      executor = -> {
        mutex.synchronize do
          inflight += 1
          peak = inflight if inflight > peak
        end
        sleep 150.milliseconds
        mutex.synchronize { inflight -= 1 }
        ::Sebas::Tools::ToolResult.success("done")
      }
      manager = ::Sebas::Agents::SubagentManager.new(store, registry, executor, max_concurrent: 2)
      4.times do |i|
        manager.spawn_subtask("owner-1", "sub-#{i}", "agent-#{i}", "p#{i}", "sess")
      end
      wait_for(5.seconds) do
        (0..3).all? { |i| store.task_status?("sub:sub-#{i}") == "done" }
      end.should be_true
      peak.should eq(2) # 上限 2：超限排队不失控（§8.3）
      store.close
    end

    it "recovers the same subtask after a crash via ownerTaskId (§14 M3 验收 找回)" do
      store = m3_tmp_store
      registry = ::Sebas::Agents::AgentRegistry.new(m3_agents_dir)
      executor = -> { ::Sebas::Tools::ToolResult.success("recovered") }
      manager = ::Sebas::Agents::SubagentManager.new(store, registry, executor)

      # 构造崩溃现场：子任务已存在且 interrupted（owner 锚点 owner-9）
      store.create_task("sub:recover-1", "subtask", parent_id: "owner-9",
        owner_task_id: "owner-9", payload: %({"agent": "agent-x"}))
      store.recover!
      store.task("sub:recover-1").status.should eq("interrupted")

      # 同 subtask_key 重派 → 找回同一 task（不新建）→ resume → done
      task_id = manager.spawn_subtask("owner-9", "recover-1", "agent-x", "again", "sess")
      task_id.should eq("sub:recover-1")
      wait_for { store.task(task_id).status == "done" }.should be_true

      recovered = manager.subtasks_of("owner-9")
      recovered.size.should eq(1) # 无新建重复任务
      store.close
    end
  end
end
