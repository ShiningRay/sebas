require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/platform/store/expectations_store"
require "../../../src/orchestration/fork/expectations"
require "../../../src/orchestration/fork/join_writer"

def jw_env
  dir = Path[Dir.tempdir, "sebas-joinwriter-spec", "#{Random::Secure.hex(4)}"]
  FileUtils.mkdir_p(dir)
  store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
  writer = ::Sebas::Orchestration::Fork::JoinWriter.new(store)
  ex = ::Sebas::Orchestration::Fork::Expectations.new(store)
  {store, writer, ex}
end

def seed_fork(store, ex, fork_id : String, mode : String, n : Int32, parent_session : String) : Array(String)
  store.create_task("parent-1", "fork_parent") unless store.task_status?("parent-1")
  members = [] of String
  n.times do |i|
    task_id = "#{fork_id}:#{i + 1}"
    store.create_task(task_id, "fork_child", parent_id: "parent-1", owner_task_id: "parent-1")
    members << task_id
  end
  ex.create(fork_id, "parent-1", parent_session, mode, members, Time.utc + 1.hour)
  members
end

module Sebas
  describe "JoinWriter 分层回写（M4.1-WP4）" do
    it "正常完成：L1 回写父会话可见（system 行含 join.report JSON），成员引用齐全" do
      store, writer, ex = jw_env
      parent_session = "agent:main:test-acc:email:alice@example.com"
      members = seed_fork(store, ex, "fork:aa111111", "allSettled", 2, parent_session)
      members.each do |task_id|
        i = task_id.split(":").last
        sk = ::Sebas::Agents.session_key("main", "internal", "fork", "fork:aa111111:#{i}")
        store.append_transcript(sk, "user", "task #{i}")
        store.append_transcript(sk, "agent", "conclusion #{i}")
        store.complete_task(task_id, "conclusion #{i}")
      end
      ex.judge("fork:aa111111")
      writer.write("fork:aa111111").should eq(::Sebas::Orchestration::Fork::JoinWriter::WriteResult::Written)

      rows = store.transcripts(parent_session)
      report_row = rows.last
      report_row.role.should eq("system")
      data = JSON.parse(report_row.content)
      data["type"].as_s.should eq("join.report")
      data["outcome"].as_s.should eq("settled")
      data["members"].as_a.size.should eq(2)
      data["members"][0]["session"].as_s.should contain("internal:fork")
      data["members"][0]["lines"].as_i.should eq(2)
      store.close
    end

    it "超时 expired：partial 由 members[].state 承载（未终态成员标 running）" do
      store, writer, ex = jw_env
      parent_session = "agent:main:test-acc:email:bob@example.com"
      seed_fork(store, ex, "fork:bb222222", "all", 2, parent_session)
      store.complete_task("fork:bb222222:1")
      row = store.expectation("fork:bb222222")
      store.transition_expectation(row.id, "open", "expired",
        settled_count: 1, result: "deadline exceeded")
      writer.write("fork:bb222222")

      rows = store.transcripts(parent_session)
      data = JSON.parse(rows.last.content)
      data["outcome"].as_s.should eq("expired")
      data["members"][1]["state"].as_s.should eq("running")
      store.close
    end

    it "非终态拒绝：open 行 write 返回 NonTerminal，不落 memo" do
      store, writer, ex = jw_env
      parent_session = "agent:main:test-acc:email:dave@example.com"
      seed_fork(store, ex, "fork:dd444444", "all", 2, parent_session)
      writer.write("fork:dd444444").should eq(::Sebas::Orchestration::Fork::JoinWriter::WriteResult::NonTerminal)
      writer.written?("fork:dd444444").should be_false # memo 未被占住
      store.close
    end

    it "any 模式：选定成功结论进 L1；all 失败 outcome=failed" do
      store, writer, ex = jw_env
      parent_session = "agent:main:test-acc:email:erin@example.com"
      members = seed_fork(store, ex, "fork:ee555555", "any", 2, parent_session)
      members.each_with_index do |task_id, i|
        sk = ::Sebas::Agents.session_key("main", "internal", "fork", "fork:ee555555:#{i + 1}")
        store.append_transcript(sk, "user", "t")
        store.append_transcript(sk, "agent", "conclusion of member #{i + 1}")
        store.complete_task(task_id, "conclusion of member #{i + 1}")
      end
      ex.judge("fork:ee555555")
      writer.write("fork:ee555555")
      data = JSON.parse(store.transcripts(parent_session).last.content)
      # any 只合并选定的先成功者（同秒并列按 members 遍历序取首个——确定性规则）；
      # 两成员 updated_at 同秒 → 选 member 1（声明序首）
      conclusions = data["members"].as_a.compact_map(&.["conclusion"]?.try(&.as_s))
      conclusions.size.should eq(1)
      conclusions.first.should eq("conclusion of member 1")
      store.close

      store, writer, ex = jw_env
      parent_session = "agent:main:test-acc:email:frank@example.com"
      seed_fork(store, ex, "fork:ff666666", "all", 2, parent_session)
      store.fail_task("fork:ff666666:1")
      store.fail_task("fork:ff666666:2")
      ex.judge("fork:ff666666")
      writer.write("fork:ff666666")
      row = store.expectation("fork:ff666666")
      row.status.should eq("settled") # 先看状态机落位
      row.result.should eq("failed")  # 再看 result 载荷
      data = JSON.parse(store.transcripts(parent_session).last.content)
      data["outcome"].as_s.should eq("failed") # all 失败映射
      store.close
    end

    it "重放不重复回写（memo 幂等）：第二次 write 返回 Duplicate，行数不变" do
      store, writer, ex = jw_env
      parent_session = "agent:main:test-acc:email:carol@example.com"
      seed_fork(store, ex, "fork:cc333333", "allSettled", 1, parent_session)
      store.complete_task("fork:cc333333:1", "done")
      ex.judge("fork:cc333333")

      writer.write("fork:cc333333").should eq(::Sebas::Orchestration::Fork::JoinWriter::WriteResult::Written)
      count_after_first = store.transcripts(parent_session).size
      writer.write("fork:cc333333").should eq(::Sebas::Orchestration::Fork::JoinWriter::WriteResult::Duplicate)
      store.transcripts(parent_session).size.should eq(count_after_first)
      writer.written?("fork:cc333333").should be_true
      store.close
    end
  end
end
