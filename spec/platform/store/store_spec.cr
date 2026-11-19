require "spec"
require "file_utils"
require "../../../src/platform/store/store"

# spec 助手（Crystal 1.22 不允许 def 直接出现在 describe 块内，置于顶层）
def temp_store(name : String) : ::Sebas::Platform::Store::Store
  dir = Path[ENV["TEMP"], "sebas-store-spec", name]
  FileUtils.rm_rf(dir)
  ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
end

module Sebas
  module Platform
    module Store
      describe "Sebas::Platform::Store::Store" do
        it "keeps WAL journal mode (Pi 口径 §15.1)" do
          store = temp_store("wal")
          # WAL 副产物 -wal 文件在连接存活期存在（Windows 实测 §15.1）
          File.exists?(store.path.to_s + "-wal").should be_true
          store.close
        end

        it "makes duplicate requestId deliveries a no-op (提交级幂等)" do
          store = temp_store("requestid")
          store.record_intent("evt-1", "message", "{}").should be_true
          store.record_intent("evt-1", "message", "{}").should be_false
          store.intent_status("evt-1").should eq("pending")
          store.finish_intent("evt-1", "dispatched")
          store.intent_status("evt-1").should eq("dispatched")
          store.finish_intent("evt-1", "done")
          store.intent_status("evt-1").should eq("done")
          store.close
        end

        it "follows the effects sandwich order: intent → checkpoint phases → result" do
          store = temp_store("sandwich")
          # 1) 执行前：意图先落库
          store.record_intent("evt-run-1", "workflow_run", %({"workflow": "w1"})).should be_true
          task = store.create_task("run-1", "run", payload: %({"workflow": "w1"}))
          task.phase.should eq(0)
          task.status.should eq("running")
          # 2) 执行中：每 phase 尾 checkpoint
          store.checkpoint("run-1", 1)
          store.task("run-1").phase.should eq(1)
          store.checkpoint("run-1", 2)
          store.task("run-1").phase.should eq(2)
          # 3) 执行后：结果落库
          store.complete_task("run-1", %({"ok": true}))
          final = store.task("run-1")
          final.status.should eq("done")
          store.intent_status("evt-run-1").should eq("pending") # 调用方标记 done
          store.finish_intent("evt-run-1", "done")
          store.intent_status("evt-run-1").should eq("done")
          store.close
        end

        it "resumes from the last checkpoint after a crash and honors restartLimit" do
          store = temp_store("recover")
          store.create_task("run-a", "run")
          store.checkpoint("run-a", 3)
          store.create_task("run-b", "run")
          store.checkpoint("run-b", 1)
          # 模拟崩溃：直接重开同一数据库（不执行优雅关闭）
          store.close
          reopened = Store.new(store.path)
          # 启动恢复：running → interrupted，restart_count+1，超限 → failed
          resumed = reopened.recover!
          resumed.map(&.id).sort!.should eq(["run-a", "run-b"])
          reopened.task("run-a").phase.should eq(3) # 重放单位 = phase：从最近 checkpoint 续跑
          reopened.task("run-a").restart_count.should eq(1)
          # 连续崩溃至 restartLimit：引擎 resume（→running）→ 再崩（recover!）往复
          4.times do
            resumed.each { |task_row| reopened.resume_task(task_row.id) }
            resumed = reopened.recover!
          end
          # 第 5 次崩溃后 restart_count=5 → failed，不再进入续跑列表
          final = reopened.recover!
          final.should be_empty
          reopened.task("run-a").status.should eq("failed")
          reopened.task("run-a").restart_count.should eq(DEFAULT_RESTART_LIMIT)
          reopened.close
        end

        it "keeps memos first-write-wins (决策级幂等)" do
          store = temp_store("memos")
          stored = store.memo_put("approval:run-1:notify", "approved")
          stored.should eq("approved")
          overwritten = store.memo_put("approval:run-1:notify", "denied")
          overwritten.should eq("approved") # 首写为准：崩溃重跑读到已存答案
          store.memo_get("approval:run-1:notify").should eq("approved")
          store.close
        end

        it "dual-writes transcripts to SQLite and JSONL" do
          store = temp_store("transcripts")
          key = "agent:main:acc1:email:peer@example.com"
          store.append_transcript(key, "user", "hello")
          store.append_transcript(key, "agent", "hi")
          rows = store.transcripts(key)
          rows.size.should eq(2)
          rows[0].role.should eq("user")
          rows[1].content.should eq("hi")
          # JSONL 双写：每行一条 JSON，会话即文件（A4）
          files = Dir.children(store.sessions_dir)
          files.size.should eq(1)
          lines = File.read_lines(store.sessions_dir / files[0])
          lines.size.should eq(2)
          first = JSON.parse(lines[0])
          first["session_key"].as_s.should eq(key)
          first["role"].as_s.should eq("user")
          store.close
        end

        it "indexes memory into FTS5 and searches it" do
          store = temp_store("fts")
          store.index_memory("memory", "MEMORY.md", "user prefers concise replies")
          store.index_memory("memory", "MEMORY.md", "user prefers concise replies (updated)")
          store.index_memory("memory", "USER.md", "owner timezone is Asia/Shanghai")
          results = store.search_memory("concise")
          results.size.should eq(1)
          results.first.key.should eq("MEMORY.md")
          results.first.body.should contain("updated")
          # 查询语法错误不炸调用方
          store.search_memory("'").should be_empty
          store.search_memory("timezone").first.key.should eq("USER.md")
          store.close
        end
      end
    end
  end
end
