require "spec"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/orchestration/fork/expectations"

def ex_env
  dir = Path[Dir.tempdir, "sebas-expectations-spec", "#{Random::Secure.hex(4)}"]
  FileUtils.mkdir_p(dir)
  store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
  ex = ::Sebas::Orchestration::Fork::Expectations.new(store)
  {store, ex}
end

# 造成员任务并落终态（tasks.status 是成员终态的单一权威）
def seed_members(store, fork_id : String, n : Int32, final : String? = nil,
                 parent_task_id : String = "parent-1") : Array(String)
  store.create_task(parent_task_id, "fork_parent") unless store.task_status?(parent_task_id)
  members = [] of String
  n.times do |i|
    task_id = "#{fork_id}:#{i + 1}"
    store.create_task(task_id, "fork_child", parent_id: parent_task_id, owner_task_id: parent_task_id)
    case final
    when "done"   then store.complete_task(task_id)
    when "failed" then store.fail_task(task_id)
    end
    members << task_id
  end
  members
end

module Sebas
  describe "Expectations (M4.1-WP2：join 汇聚点 + mode 判定器)" do
    it "all：全部成功 → settled；有失败 → settled(result=failed) 且仍等全部到位（不短路）" do
      store, ex = ex_env
      members = seed_members(store, "fork:a", 3, final: "done")
      ex.create("fork:a", "parent-1", "agent:main:test:email:p", "all", members, Time.utc + 1.hour)
      row = ex.judge("fork:a")
      row.status.should eq("settled")
      row.result.should eq("settled")
      row.settled_count.should eq(3)
      store.close

      # 不短路：2 done + 1 running → 仍 open；第三个失败落定后 → settled(result=failed)
      store, ex = ex_env
      members = seed_members(store, "fork:b", 2, final: "done")
      store.create_task("fork:b:3", "fork_child", parent_id: "parent-1", owner_task_id: "parent-1")
      members << "fork:b:3"
      ex.create("fork:b", "parent-1", "agent:main:test:email:p", "all", members, Time.utc + 1.hour)
      row = ex.judge("fork:b")
      row.status.should eq("open")
      store.fail_task("fork:b:3")
      row = ex.judge("fork:b")
      row.status.should eq("settled")
      row.result.should eq("failed")
      row.settled_count.should eq(3)
      store.close
    end

    it "any：首个成功即 settle；全失败未到期保持 open，到期 → expired" do
      store, ex = ex_env
      members = seed_members(store, "fork:c", 2)
      ex.create("fork:c", "parent-1", "agent:main:test:email:p", "any", members, Time.utc + 1.hour)
      store.fail_task("fork:c:1")
      row = ex.judge("fork:c")
      row.status.should eq("open")
      store.complete_task("fork:c:2")
      row = ex.judge("fork:c")
      row.status.should eq("settled")
      row.result.should eq("first success: fork:c:2")
      store.close

      store, ex = ex_env
      members = seed_members(store, "fork:d", 2, final: "failed")
      ex.create("fork:d", "parent-1", "agent:main:test:email:p", "any", members, Time.utc - 1.minute)
      row = ex.judge("fork:d")
      row.status.should eq("expired")
      row.result.to_s.should contain("deadline exceeded")
      store.close
    end

    it "allSettled：失败计入 settled_count，整体恒 settled" do
      store, ex = ex_env
      members = seed_members(store, "fork:e", 3)
      ex.create("fork:e", "parent-1", "agent:main:test:email:p", "allSettled", members, Time.utc + 1.hour)
      store.complete_task("fork:e:1")
      store.fail_task("fork:e:2")
      row = ex.judge("fork:e")
      row.status.should eq("open")
      store.complete_task("fork:e:3")
      row = ex.judge("fork:e")
      row.status.should eq("settled")
      row.settled_count.should eq(3)
      row.result.should eq("settled")
      store.close
    end

    it "强杀后 open expectation 续判且已 settled 行不被重复迁移（恢复幂等）" do
      store, ex = ex_env
      members = seed_members(store, "fork:f", 2)
      ex.create("fork:f", "parent-1", "agent:main:test:email:p", "allSettled", members, Time.utc + 1.hour)
      store.complete_task("fork:f:1")
      store.complete_task("fork:f:2")

      # 模拟崩溃重启：全新 Expectations 实例扫同一 store
      ex2 = ::Sebas::Orchestration::Fork::Expectations.new(store)
      ex2.recover.should eq(1)
      row = store.expectation("fork:f")
      row.status.should eq("settled")
      row.settled_count.should eq(2)

      # 再跑恢复：已 settled 不再迁移（judged=0），updated_at 不变
      ex2.recover.should eq(0)
      store.expectation("fork:f").status.should eq("settled")
      store.expectation("fork:f").updated_at.should eq(row.updated_at)
      store.close
    end

    it "cancel 只旁路 open；非法 mode 登记即拒" do
      store, ex = ex_env
      members = seed_members(store, "fork:g", 1)
      ex.create("fork:g", "parent-1", "agent:main:test:email:p", "any", members, Time.utc + 1.hour)
      ex.cancel("fork:g")
      store.expectation("fork:g").status.should eq("cancelled")
      store.close

      store, ex = ex_env
      expect_raises(::Sebas::Platform::Store::StoreError, "非法 join mode") do
        ex.create("fork:h", "parent-1", "agent:main:test:email:p", "some", members, Time.utc + 1.hour)
      end
      store.close
    end
  end
end

# #42 第一轮复审（settling 恢复 + any 首个成功顺序）回归。
def seed_done_at(store, fork_id : String, order : Hash(String, Time), parent_task_id : String = "parent-1") : Array(String)
  store.create_task(parent_task_id, "fork_parent") unless store.task_status?(parent_task_id)
  members = [] of String
  order.keys.each do |task_id|
    store.create_task(task_id, "fork_child", parent_id: parent_task_id, owner_task_id: parent_task_id)
    members << task_id
    store.complete_task(task_id)
    # 把 updated_at 改写成受控时刻（SQLite 直接 UPDATE，模拟先后完成）
    db = store.db
    db.exec("UPDATE tasks SET updated_at = ? WHERE id = ?", order[task_id].to_rfc3339, task_id)
  end
  members
end

module Sebas
  describe "Expectations 恢复与 any 顺序（#42 复审）" do
    it "settling 中断恢复：不重放第一步，直接收尾到 settled（且 deadline 处理仍生效）" do
      dir = Path[Dir.tempdir, "sebas-expectations-settling", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir)
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      ex = ::Sebas::Orchestration::Fork::Expectations.new(store)
      members = seed_members(store, "fork:s", 2, final: "done")
      ex.create("fork:s", "parent-1", "agent:main:test:email:p", "allSettled", members, Time.utc + 1.hour)
      # 模拟 settle 两步迁移间崩溃：手工只提交第一步
      db = store.db
      db.exec("UPDATE expectations SET status = 'settling' WHERE fork_id = 'fork:s'")

      ex2 = ::Sebas::Orchestration::Fork::Expectations.new(store)
      row = ex2.judge("fork:s")
      row.status.should eq("settled")
      row.settled_count.should eq(2)
      store.close
    end

    it "any：多个成员均已 done 时 result 指向 updated_at 最早（先成功）者" do
      dir = Path[Dir.tempdir, "sebas-expectations-any", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir)
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      ex = ::Sebas::Orchestration::Fork::Expectations.new(store)
      # members 顺序 [A, B]；B（后位）先成功（updated_at 更早）
      t0 = Time.utc - 10.minutes
      members = seed_done_at(store, "fork:ord", {
        "fork:ord:A" => t0 + 5.minutes, # A 后成功
        "fork:ord:B" => t0,             # B 先成功
      })
      ex.create("fork:ord", "parent-1", "agent:main:test:email:p", "any", members, Time.utc + 1.hour)
      row = ex.judge("fork:ord")
      row.status.should eq("settled")
      row.result.should eq("first success: fork:ord:B")
      store.close
    end
  end
end
