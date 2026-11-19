require "db"
require "sqlite3"
require "json"
require "digest/sha256"
require "../../log"

# 持久层（M0-WP3）：SQLite(WAL) 主存储 + JSONL 转录双写 + FTS5 检索（design.md §6/§7.2/§7.3）
#
# 效应三明治（§7.2 拒绝事件溯源）：
#   执行前 intents 落库 → 执行中每 phase 尾 checkpoint → 执行后结果落库
# 幂等三件套（§7.3）：
#   提交级 requestId（intents.id 主键）/ 工具级 replay 二分（M0-WP6）/ 决策级 memo first-write-wins
module Sebas
  module Platform
    module Store
      class StoreError < ::Exception; end

      # 崩溃循环防护上限（§7.3，Pi §4）：连续被打断 N 次的任务终止而非再跑
      DEFAULT_RESTART_LIMIT = 5

      record TaskRow,
        id : String, parent_id : String?, kind : String, status : String,
        phase : Int32, restart_count : Int32, owner_task_id : String?

      record TranscriptRow, id : Int64, session_key : String, role : String, content : String, created_at : String

      record SearchRow, kind : String, key : String, body : String

      # 逐条执行（crystal-sqlite3 prepared statement 一次只接受一条语句）
      SCHEMA = [
        <<-SQL,
          CREATE TABLE IF NOT EXISTS intents (
            id         TEXT PRIMARY KEY,
            kind       TEXT NOT NULL,
            payload    TEXT,
            status     TEXT NOT NULL DEFAULT 'pending',
            created_at TEXT NOT NULL
          )
          SQL
        <<-SQL,
          CREATE TABLE IF NOT EXISTS tasks (
            id             TEXT PRIMARY KEY,
            parent_id      TEXT REFERENCES tasks(id),
            kind           TEXT NOT NULL,
            status         TEXT NOT NULL DEFAULT 'running',
            phase          INTEGER NOT NULL DEFAULT 0,
            payload        TEXT,
            result         TEXT,
            restart_count  INTEGER NOT NULL DEFAULT 0,
            owner_task_id  TEXT,
            created_at     TEXT NOT NULL,
            updated_at     TEXT NOT NULL
          )
          SQL
        <<-SQL,
          CREATE TABLE IF NOT EXISTS transcripts (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            session_key TEXT NOT NULL,
            role        TEXT NOT NULL,
            content     TEXT NOT NULL,
            created_at  TEXT NOT NULL
          )
          SQL
        "CREATE INDEX IF NOT EXISTS idx_transcripts_session ON transcripts(session_key, id)",
        <<-SQL,
          CREATE TABLE IF NOT EXISTS memos (
            key        TEXT PRIMARY KEY,
            value      TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
          SQL
        "CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(" \
        "kind UNINDEXED, key UNINDEXED, body, tokenize='unicode61')",
      ]

      class Store
        getter path : Path
        getter sessions_dir : Path

        @db : ::DB::Database

        def initialize(db_path : String | Path, sessions_dir : String | Path? = nil)
          @path = Path[db_path].expand
          Dir.mkdir_p(@path.parent) unless Dir.exists?(@path.parent)
          @sessions_dir = sessions_dir ? Path[sessions_dir] : @path.parent / "sessions"
          uri = "sqlite3:#{@path.to_s.gsub('\\', '/')}" \
                "?initial_pool_size=1&max_pool_size=1&checkout_timeout=5"
          @db = ::DB.open(uri)
          # Pi 口径（§15.1 WAL）：WAL + synchronous=NORMAL——掉电可丢最新一笔，进程级强杀不丢
          @db.exec("PRAGMA journal_mode=WAL")
          @db.exec("PRAGMA synchronous=NORMAL")
          @db.exec("PRAGMA busy_timeout=5000")
          SCHEMA.each { |ddl| @db.exec(ddl) }
          Sebas::Log.info { "store opened: #{@path} (journal_mode=#{@db.scalar("PRAGMA journal_mode")})" }
        end

        def close : Nil
          @db.close
        end

        # ---- 提交级幂等：intents（requestId = 入站事件 ID，§7.3）----

        # 意图先落库；同 requestId 二次投递返回 false（不产生第二行、不重跑）
        def record_intent(request_id : String, kind : String, payload : String? = nil) : Bool
          rows = @db.exec(
            "INSERT OR IGNORE INTO intents (id, kind, payload, status, created_at) VALUES (?, ?, ?, 'pending', ?)",
            request_id, kind, payload, now
          ).rows_affected
          rows > 0
        end

        # 启动恢复：未完成 intents（pending/dispatched）→ 重新投递队列（M0-WP8 强杀续跑）
        record IntentRow, id : String, kind : String, payload : String, status : String

        # 前缀查询 intents（触发器/管理面 runs.list 复用）
        def intents_with_prefix(prefix : String) : Array(IntentRow)
          rows = [] of IntentRow
          @db.query("SELECT id, kind, payload, status FROM intents WHERE id LIKE ? || '%' ORDER BY created_at", prefix) do |result_set|
            result_set.each do
              rows << IntentRow.new(result_set.read(String), result_set.read(String), result_set.read(String), result_set.read(String))
            end
          end
          rows
        end

        def unfinished_intents : Array(IntentRow)
          rows = [] of IntentRow
          @db.query("SELECT id, kind, payload, status FROM intents WHERE status IN ('pending', 'dispatched') ORDER BY created_at") do |result_set|
            result_set.each do
              rows << IntentRow.new(result_set.read(String), result_set.read(String), result_set.read(String), result_set.read(String))
            end
          end
          rows
        end

        def intent_status(request_id : String) : String?
          @db.query_one?("SELECT status FROM intents WHERE id = ?", request_id, as: String)
        end

        def finish_intent(request_id : String, status : String) : Nil
          raise StoreError.new("unknown intent #{request_id}") unless {"dispatched", "done", "failed"}.includes?(status)
          @db.exec("UPDATE intents SET status = ? WHERE id = ?", status, request_id)
        end

        # ---- 任务树：phase checkpoint（重放单位 = phase，§7.2）----

        def create_task(id : String, kind : String, parent_id : String? = nil,
                        owner_task_id : String? = nil, payload : String? = nil) : TaskRow
          @db.exec(
            "INSERT INTO tasks (id, parent_id, kind, status, phase, payload, restart_count, owner_task_id, created_at, updated_at) " \
            "VALUES (?, ?, ?, 'running', 0, ?, 0, ?, ?, ?)",
            id, parent_id, kind, payload, owner_task_id, now, now
          )
          task!(id)
        end

        # phase 尾 commit checkpoint：崩溃后从最后一个 checkpoint 续跑
        def checkpoint(task_id : String, phase : Int32) : Nil
          changed = @db.exec("UPDATE tasks SET phase = ?, updated_at = ? WHERE id = ?", phase, now, task_id).rows_affected
          raise StoreError.new("unknown task #{task_id}") if changed == 0
        end

        def complete_task(task_id : String, result : String? = nil) : Nil
          changed = @db.exec("UPDATE tasks SET status = 'done', result = ?, updated_at = ? WHERE id = ?",
            result, now, task_id).rows_affected
          raise StoreError.new("unknown task #{task_id}") if changed == 0
        end

        def fail_task(task_id : String, error : String? = nil) : Nil
          changed = @db.exec("UPDATE tasks SET status = 'failed', result = ?, updated_at = ? WHERE id = ?",
            error, now, task_id).rows_affected
          raise StoreError.new("unknown task #{task_id}") if changed == 0
        end

        def task(id : String) : TaskRow
          task!(id)
        end

        # 启动恢复：running 状态的任务视为被打断（崩溃续跑入口，M0-WP8 演练用）。
        # restart_count+1；达到 restartLimit 的任务终止为 failed（崩溃循环防护）。
        # 返回可续跑任务（含最近 checkpoint phase）。
        def recover!(restart_limit : Int32 = DEFAULT_RESTART_LIMIT) : Array(TaskRow)
          @db.exec("UPDATE tasks SET status = 'interrupted', restart_count = restart_count + 1, updated_at = ? WHERE status = 'running'", now)
          @db.exec("UPDATE tasks SET status = 'failed', result = 'restart limit exceeded', updated_at = ? WHERE status = 'interrupted' AND restart_count >= ?", now, restart_limit)
          resumed = query_tasks("status = 'interrupted'")
          Sebas::Log.info { "recover: #{resumed.size} interrupted task(s) resumable" }
          resumed
        end

        # 引擎恢复执行入口：interrupted → running（再次崩溃由 recover! 记入 restart_count）
        def resume_task(task_id : String) : Nil
          changed = @db.exec("UPDATE tasks SET status = 'running', updated_at = ? WHERE id = ?", now, task_id).rows_affected
          raise StoreError.new("unknown task #{task_id}") if changed == 0
        end

        TASK_COLUMNS = "id, parent_id, kind, status, phase, restart_count, owner_task_id"

        private def query_tasks(where : String) : Array(TaskRow)
          rows = [] of TaskRow
          @db.query("SELECT #{TASK_COLUMNS} FROM tasks WHERE #{where}") do |result_set|
            result_set.each { rows << read_task(result_set) }
          end
          rows
        end

        private def task!(id : String) : TaskRow
          @db.query_one("SELECT #{TASK_COLUMNS} FROM tasks WHERE id = ?", id) { |result_set| read_task(result_set) }
        end

        # 位置式读取（crystal-db 不支持任意 record 的 as: 映射）
        private def read_task(result_set : ::DB::ResultSet) : TaskRow
          id = result_set.read(String)
          parent_id = result_set.read(String?)
          kind = result_set.read(String)
          status = result_set.read(String)
          phase = result_set.read(Int64).to_i32
          restart_count = result_set.read(Int64).to_i32
          owner_task_id = result_set.read(String?)
          TaskRow.new(id, parent_id, kind, status, phase, restart_count, owner_task_id)
        end

        # ---- 决策级幂等：memo first-write-wins（§7.3）----

        def memo_put(key : String, value : String) : String
          @db.exec("INSERT OR IGNORE INTO memos (key, value, created_at) VALUES (?, ?, ?)", key, value, now)
          @db.query_one("SELECT value FROM memos WHERE key = ?", key, as: String)
        end

        def memo_get(key : String) : String?
          @db.query_one?("SELECT value FROM memos WHERE key = ?", key, as: String)
        end

        # 状态机值更新（intent→done/failed）：单写者内覆盖，不影响决策级 memo 的 FWW 语义
        def memo_replace(key : String, value : String) : Nil
          sql = "INSERT INTO memos (key, value, created_at) VALUES (?, ?, ?) " \
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value"
          @db.exec(sql, key, value, now)
        end

        # ---- 会话转录：SQLite 权威 + JSONL 人可读归档双写（§6.1，A4 升级）----

        def append_transcript(session_key : String, role : String, content : String) : Nil
          created = now
          @db.exec("INSERT INTO transcripts (session_key, role, content, created_at) VALUES (?, ?, ?, ?)",
            session_key, role, content, created)
          Dir.mkdir_p(@sessions_dir) unless Dir.exists?(@sessions_dir)
          File.open(jsonl_path(session_key), "a") do |io|
            io.puts({ts: created, session_key: session_key, role: role, content: content}.to_json)
          end
        end

        # 管理面：会话键列表（sessions.list）
        def session_keys : Array(String)
          keys = [] of String
          @db.query("SELECT DISTINCT session_key FROM transcripts ORDER BY session_key") do |result_set|
            result_set.each { keys << result_set.read(String) }
          end
          keys
        end

        def transcripts(session_key : String) : Array(TranscriptRow)
          rows = [] of TranscriptRow
          @db.query(
            "SELECT id, session_key, role, content, created_at FROM transcripts WHERE session_key = ? ORDER BY id",
            session_key
          ) do |result_set|
            result_set.each do
              rows << TranscriptRow.new(result_set.read(Int64), result_set.read(String), result_set.read(String), result_set.read(String), result_set.read(String))
            end
          end
          rows
        end

        # 会话键含路径非法字符（":" 等），清洗并追加短哈希保证唯一（§3.3）
        private def jsonl_path(session_key : String) : Path
          safe = session_key.gsub(/[^A-Za-z0-9._-]/, "_")
          digest = ::Digest::SHA256.hexdigest(session_key)[0, 8]
          @sessions_dir / "#{safe}-#{digest}.jsonl"
        end

        # ---- FTS5 检索（§6.2）：记忆与会话全文索引 ----

        def index_memory(kind : String, key : String, body : String) : Nil
          @db.exec("DELETE FROM search WHERE key = ?", key)
          @db.exec("INSERT INTO search (kind, key, body) VALUES (?, ?, ?)", kind, key, body)
        end

        def search_memory(query : String, limit : Int32 = 20) : Array(SearchRow)
          return [] of SearchRow if query.strip.empty?
          rows = [] of SearchRow
          @db.query("SELECT kind, key, body FROM search WHERE search MATCH ? ORDER BY rank LIMIT ?",
            query, limit) do |result_set|
            result_set.each { rows << SearchRow.new(result_set.read(String), result_set.read(String), result_set.read(String)) }
          end
          rows
        rescue ex : ::DB::Error | ::SQLite3::Exception
          # FTS5 语法错误（如裸引号）不炸调用方（SQLite3::Exception 非 DB::Error 子类）
          Sebas::Log.warn { "fts query rejected: #{ex.message}" }
          [] of SearchRow
        end

        private def now : String
          ::Time.utc.to_rfc3339
        end
      end
    end
  end
end
