require "db"
require "sqlite3"
require "json"
require "./expectations_store"
require "./task_effects_store"
require "./steer_store"
require "./scheduling_overlay_store"
require "./telegram_store"
require "digest/sha256"
require "../../log"
require "../../sessions/scheduling/policy"
require "../../sessions/scheduling/envelope"

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

      # 存量库列迁移：CREATE TABLE IF NOT EXISTS 不改既有表——members_final
      # 为基线后新增列，ALTER TABLE 幂等补列（duplicate column 静默忽略，见 initialize）
      MIGRATIONS = [
        "ALTER TABLE expectations ADD COLUMN members_final INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE session_steers ADD COLUMN dispatch_event_id TEXT",
      ]

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
        <<-SQL,
          CREATE TABLE IF NOT EXISTS ledger (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            ts      TEXT NOT NULL,
            run_id  TEXT NOT NULL,
            kind    TEXT NOT NULL,
            payload TEXT
          )
          SQL
        "CREATE INDEX IF NOT EXISTS idx_ledger_run ON ledger(run_id, id)",
        <<-SQL,
          CREATE TABLE IF NOT EXISTS leases (
            task_id    TEXT PRIMARY KEY,
            owner      TEXT NOT NULL,
            expires_at TEXT NOT NULL
          )
          SQL
        # ---- 会话输入调度（session-input-scheduling.md §5.1；M3-WP1）----
        #
        # 唯一约束即契约：event_id 唯一（一批多事件共享 batch，event 不双归属）、
        # batch_id + position 唯一（批内顺序不可重排）。
        <<-SQL,
          CREATE TABLE IF NOT EXISTS session_inputs (
            event_id          TEXT PRIMARY KEY,
            session_key       TEXT NOT NULL,
            source            TEXT NOT NULL,
            sender            TEXT NOT NULL,
            received_seq      INTEGER NOT NULL,
            received_at       TEXT NOT NULL,
            source_occurred_at TEXT,
            payload           TEXT NOT NULL,
            policy_snapshot   TEXT NOT NULL,
            status            TEXT NOT NULL DEFAULT 'accepted',
            batch_id          TEXT
          )
          SQL
        "CREATE INDEX IF NOT EXISTS idx_session_inputs_batch ON session_inputs(batch_id, received_seq)",
        "CREATE INDEX IF NOT EXISTS idx_session_inputs_session_seq ON session_inputs(session_key, received_seq)",
        <<-SQL,
          CREATE TABLE IF NOT EXISTS session_batches (
            batch_id        TEXT PRIMARY KEY,
            session_key     TEXT NOT NULL,
            status          TEXT NOT NULL DEFAULT 'collecting',
            policy_snapshot TEXT NOT NULL,
            first_seq       INTEGER NOT NULL,
            last_seq        INTEGER NOT NULL,
            seal_reason     TEXT,
            created_at      TEXT NOT NULL,
            sealed_at       TEXT
          )
          SQL
        "CREATE INDEX IF NOT EXISTS idx_session_batches_session ON session_batches(session_key, status)",
        <<-SQL,
          CREATE TABLE IF NOT EXISTS session_batch_members (
            event_id TEXT PRIMARY KEY,
            batch_id TEXT NOT NULL,
            position INTEGER NOT NULL
          )
          SQL
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_session_batch_members_order ON session_batch_members(batch_id, position)",
        <<-SQL,
          CREATE TABLE IF NOT EXISTS session_steers (
            steer_id         TEXT PRIMARY KEY,
            session_key      TEXT NOT NULL,
            target_turn_id   TEXT NOT NULL,
            target_generation INTEGER NOT NULL,
            payload          TEXT NOT NULL,
            status           TEXT NOT NULL DEFAULT 'accepted',
            reason           TEXT,
            dispatch_event_id TEXT,
            created_at       TEXT NOT NULL,
            updated_at       TEXT NOT NULL
          )
          SQL
        # steer 查询索引（M4.5-WP4 CodeRabbit）：expire_due 100ms 轮询按
        # status 扫描；drain/submit 按 session+status 过滤——终态行不删，
        # 无索引则全表扫描随增长劣化（IF NOT EXISTS 对存量库生效）
        <<-SQL,
          CREATE INDEX IF NOT EXISTS idx_session_steers_status_created
            ON session_steers (status, created_at)
          SQL
        <<-SQL,
          CREATE INDEX IF NOT EXISTS idx_session_steers_session_status
            ON session_steers (session_key, status, created_at)
          SQL
        <<-SQL,
          CREATE TABLE IF NOT EXISTS scheduling_meta (
            id       INTEGER PRIMARY KEY CHECK (id = 1),
            revision INTEGER NOT NULL
          )
          SQL
        <<-SQL,
          CREATE TABLE IF NOT EXISTS scheduling_overlays (
            scope       TEXT PRIMARY KEY,
            patch_yaml  TEXT NOT NULL,
            revision    INTEGER NOT NULL,
            operator    TEXT NOT NULL,
            updated_at  TEXT NOT NULL
          )
          SQL
        "CREATE TABLE IF NOT EXISTS sessions (" \
        "session_key     TEXT PRIMARY KEY, " \
        "agent_id        TEXT NOT NULL, " \
        "kind            TEXT NOT NULL DEFAULT 'user', " \
        "fork_id         TEXT, " \
        "status          TEXT NOT NULL DEFAULT 'active', " \
        "last_active_at  TEXT NOT NULL, " \
        "created_at      TEXT NOT NULL, " \
        "archived_path   TEXT)",
        "CREATE TABLE IF NOT EXISTS expectations (" \
        "id             TEXT PRIMARY KEY, " \
        "members_final  INTEGER NOT NULL DEFAULT 0, " \
        "fork_id        TEXT NOT NULL, " \
        "parent_task_id TEXT NOT NULL REFERENCES tasks(id), " \
        "parent_session TEXT NOT NULL, " \
        "mode           TEXT NOT NULL, " \
        "deadline       TEXT NOT NULL, " \
        "members        TEXT NOT NULL, " \
        "settled_count  INTEGER NOT NULL DEFAULT 0, " \
        "status         TEXT NOT NULL DEFAULT 'open', " \
        "result         TEXT, " \
        "created_at     TEXT NOT NULL, " \
        "updated_at     TEXT NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_expectations_fork ON expectations(fork_id)",
        # ---- Telegram 适配器（M3-WP8；m8 提案 §4.2 第 5 点）----
        #
        # telegram_accounts：每账号轮询状态。persisted_offset=最后确认的 update_id
        # （0 = 从未确认）；last_update_at=最近一次非空 getUpdates 响应到达时刻
        # （空响应不刷新）；reset_mode=空闲重置模式跨崩溃延续位。
        <<-SQL,
          CREATE TABLE IF NOT EXISTS telegram_accounts (
            account_id       TEXT PRIMARY KEY,
            persisted_offset INTEGER NOT NULL DEFAULT 0,
            last_update_at   TEXT,
            reset_mode       INTEGER NOT NULL DEFAULT 0
          )
          SQL
        # telegram_updates：写入顺序纪律三步的持久底座。event_id 主键（确定性
        # 派生 `tg:<account_id>:<sha256(update_id || ":" || content_fingerprint)>`）；
        # (account_id, content_fingerprint) 唯一索引=跨重置周期内容排重兜底；
        # dispatched 由消费者侧置位；status='pending'|'dead_letter'（dead_letter
        # 被两条扫描路径排除）；retry_count 仅供 record_intent 失败计数（调度器
        # 扩展 #252 消费）；bus_publish_timeout_count 为 bus 饱和观测计数。
        <<-SQL,
          CREATE TABLE IF NOT EXISTS telegram_updates (
            event_id            TEXT PRIMARY KEY,
            account_id          TEXT NOT NULL,
            update_id           INTEGER NOT NULL,
            content_fingerprint TEXT NOT NULL,
            raw_payload         TEXT NOT NULL,
            dispatched          INTEGER NOT NULL DEFAULT 0,
            status              TEXT NOT NULL DEFAULT 'pending',
            retry_count         INTEGER NOT NULL DEFAULT 0,
            bus_publish_timeout_count INTEGER NOT NULL DEFAULT 0,
            created_at          TEXT NOT NULL
          )
          SQL
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_telegram_updates_fp ON telegram_updates(account_id, content_fingerprint)",
        "CREATE INDEX IF NOT EXISTS idx_telegram_updates_pending ON telegram_updates(account_id, status, update_id)",
      ]

      class Store
        include ::Sebas::Platform::TaskEffectsStoreMethods
        include ::Sebas::Platform::SteerStoreMethods
        include ::Sebas::Platform::SchedulingOverlayStoreMethods
        include ::Sebas::Platform::ExpectationStoreMethods
        include ::Sebas::Platform::TelegramStoreMethods

        getter db : ::DB::Database
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
          # 存量库列迁移：CREATE TABLE IF NOT EXISTS 不改既有表。新库 SCHEMA 已含
          # 全部列，ALTER 撞 duplicate 属预期（幂等静默）；只有存量旧库会真正补列。
          MIGRATIONS.each do |sql|
            @db.exec(sql)
          rescue ex : SQLite3::Exception
            # do-end 块后不能直接挂 rescue；SQLite3::Exception 不继承 DB::Error，
            # 必须显式捕获该类型。duplicate = 列已在（新库 SCHEMA 建过），幂等跳过。
            raise ex unless ex.message.to_s.includes?("duplicate column")
          end
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

        # ---- append-only 事件账本（§7.4；runs 回放审计 M2-WP6 消费）----

        record LedgerRow, id : Int64, ts : String, run_id : String, kind : String, payload : String

        def ledger_append(run_id : String, kind : String, payload : String = "") : Nil
          @db.exec("INSERT INTO ledger (ts, run_id, kind, payload) VALUES (?, ?, ?, ?)",
            now, run_id, kind, payload)
        end

        def ledger_replay(run_id : String) : Array(LedgerRow)
          rows = [] of LedgerRow
          @db.query("SELECT id, ts, run_id, kind, payload FROM ledger WHERE run_id = ? ORDER BY id", run_id) do |result_set|
            result_set.each do
              rows << LedgerRow.new(result_set.read(Int64), result_set.read(String), result_set.read(String), result_set.read(String), result_set.read(String))
            end
          end
          rows
        end

        # ---- 任务 lease（§7.4：租约+过期回收）----

        # 获取租约：已存在且未过期 → false；过期/不存在 → 取得（重派口径）
        def lease_acquire(task_id : String, owner : String, ttl : Time::Span = 60.seconds) : Bool
          existing = @db.query_one?("SELECT owner, expires_at FROM leases WHERE task_id = ?", task_id) do |result_set|
            {result_set.read(String), result_set.read(String)}
          end
          if existing
            _, expires = existing
            return false if ::Time.parse_rfc3339(expires) > ::Time.utc # 未过期：他人持有
            @db.exec("DELETE FROM leases WHERE task_id = ?", task_id)  # 过期回收
          end
          @db.exec("INSERT INTO leases (task_id, owner, expires_at) VALUES (?, ?, ?)",
            task_id, owner, (::Time.utc + ttl).to_rfc3339)
          true
        end

        def lease_heartbeat(task_id : String, owner : String, ttl : Time::Span = 60.seconds) : Bool
          changed = @db.exec("UPDATE leases SET expires_at = ? WHERE task_id = ? AND owner = ?",
            (::Time.utc + ttl).to_rfc3339, task_id, owner).rows_affected
          changed > 0
        end

        def lease_release(task_id : String, owner : String) : Nil
          @db.exec("DELETE FROM leases WHERE task_id = ? AND owner = ?", task_id, owner)
        end

        # 回收所有过期租约（返回被回收的 task ids）
        def lease_reap_expired : Array(String)
          ids = [] of String
          @db.query("SELECT task_id FROM leases WHERE expires_at <= ?", ::Time.utc.to_rfc3339) do |result_set|
            result_set.each { ids << result_set.read(String) }
          end
          ids.each { |id| @db.exec("DELETE FROM leases WHERE task_id = ?", id) }
          ids
        end

        # run task 状态（不存在返回 nil；不抛行缺失异常）
        def task_status?(task_id : String) : String?
          @db.query_one?("SELECT status FROM tasks WHERE id = ?", task_id, as: String)
        end

        # 任务状态迁移时刻（ISO-8601）：成员「成功先后」的唯一可持久化证据（any 判定）。
        def task_updated_at(task_id : String) : String?
          @db.query_one?("SELECT updated_at FROM tasks WHERE id = ?", task_id, as: String)
        end

        # owner 的全部子任务（Pi ownership 找回口径，M3-WP3）
        def tasks_by_owner(owner_task_id : String) : Array(TaskRow)
          rows = [] of TaskRow
          @db.query("SELECT #{TASK_COLUMNS} FROM tasks WHERE owner_task_id = ? ORDER BY id", owner_task_id) do |result_set|
            result_set.each { rows << read_task(result_set) }
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

        EXPECTATION_COLUMNS = "id, fork_id, parent_task_id, parent_session, mode, deadline, members, settled_count, status, result, created_at, updated_at"

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

        # join.report 落库与 memo 幂等标记的原子提交（#152 CodeRabbit）：
        # 同一事务两条语句（max_pool_size=1，块内复用 checkout 的方法会死锁，
        # 故实现为单方法而非通用 transaction 块）。
        # 附带 JSONL 归档（append_transcript 同款双写；JSONL 失败抛错前 DB 已提交，
        # 重放被 memo 挡住——缺 JSONL 行可由 DB 权威重建，另卡）。
        def write_join_report(session_key : String, content : String, memo_key : String, memo_value : String) : Nil
          @db.transaction do |tx|
            conn = tx.connection
            created = ::Time.utc.to_rfc3339
            conn.exec("INSERT INTO transcripts (session_key, role, content, created_at) VALUES (?, ?, ?, ?)",
              session_key, "system", content, created)
            conn.exec("INSERT INTO memos (key, value, created_at) VALUES (?, ?, ?) " \
                      "ON CONFLICT(key) DO UPDATE SET value = excluded.value", memo_key, memo_value, created)
            append_jsonl(session_key, "system", content, created)
          end
        end

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
          append_jsonl(session_key, role, content, append_transcript_row(session_key, role, content))
        end

        # DB 行写入（返回 created 时刻），JSONL 归档由调用方决定是否同批
        private def append_transcript_row(session_key : String, role : String, content : String) : String
          created = now
          @db.exec("INSERT INTO transcripts (session_key, role, content, created_at) VALUES (?, ?, ?, ?)",
            session_key, role, content, created)
          created
        end

        private def append_jsonl(session_key : String, role : String, content : String, created : String) : Nil
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

        # ---- 会话输入调度持久化（session-input-scheduling.md §5；M3-WP1）----
        #
        # admission 原子性（契约 §4.2）：去重（event_id 主键）、原文持久化、
        # 加入批次在同一 SQLite 事务内完成，成功才对渠道 ACK。
        # 返回 false = 同 event_id 已存在（重复投递，幂等不重跑）。

        def admit_session_input(env : ::Sebas::Sessions::Scheduling::InputEnvelope, batch : ::Sebas::Sessions::Scheduling::Batch,
                                position : Int64) : Bool
          inserted = false
          @db.transaction do |tx|
            connection = tx.connection
            # 去重先于状态守卫：同 event_id 重投（即使其原批次已被 seal）按幂等
            # 返回 false，不抛错——文档契约「同 event_id 二次投递返回 false」
            dup_rows = connection.exec(
              "INSERT OR IGNORE INTO session_inputs " \
              "(event_id, session_key, source, sender, received_seq, received_at, source_occurred_at, payload, policy_snapshot, status, batch_id) " \
              "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'batched', ?)",
              env.event_id, env.session_key, env.source, env.sender, env.received_seq,
              env.received_at, env.source_occurred_at, env.payload,
              env.policy_snapshot.to_json, batch.batch_id
            ).rows_affected
            next unless dup_rows > 0
            # 状态守卫在去重之后：新事件才需要批次为 collecting
            stored_status = connection.query_one?(
              "SELECT status FROM session_batches WHERE batch_id = ?", batch.batch_id, as: String)
            unless stored_status == ::Sebas::Sessions::Scheduling::BatchStatus::Collecting.to_s
              raise StoreError.new("batch #{batch.batch_id} is #{stored_status || "missing"}, not collecting — admission rejected")
            end
            inserted = true
            connection.exec(
              "INSERT INTO session_batch_members (event_id, batch_id, position) VALUES (?, ?, ?)",
              env.event_id, batch.batch_id, position
            )
            # 扩展批次的持久序号范围（批次记录须反映其实际覆盖的接收序）
            connection.exec(
              "UPDATE session_batches SET last_seq = MAX(last_seq, ?) WHERE batch_id = ?",
              env.received_seq, batch.batch_id
            )
          end
          inserted
        end

        # 去重前置探测（admission 序：先探重再建批，避免 duplicate 路径留孤儿批次；
        # 竞态仍由 admit_session_input 的 event_id 主键原子守卫兜底）
        # admission 解析结果回查（M4.5-WP6/#176）：replay 时按 event_id 取
        # envelope 的 session_key 作为 admitted_session——binding 热换不影响
        # 在途/未完成事件归属（无 envelope 行返回 nil，调用方回落 binding 解析）
        def session_input_session_key(event_id : String) : String?
          @db.query_one?(
            "SELECT session_key FROM session_inputs WHERE event_id = ?", event_id, as: String
          )
        end

        def session_input?(event_id : String) : Bool
          count = @db.query_one("SELECT COUNT(*) FROM session_inputs WHERE event_id = ?", event_id, as: Int64)
          count.positive?
        end

        def create_session_batch(batch : ::Sebas::Sessions::Scheduling::Batch) : Nil
          @db.exec(
            "INSERT INTO session_batches (batch_id, session_key, status, policy_snapshot, first_seq, last_seq, seal_reason, created_at, sealed_at) " \
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            batch.batch_id, batch.session_key, batch.status.to_s, batch.policy_snapshot.to_json,
            batch.first_seq, batch.last_seq, batch.seal_reason, batch.created_at, batch.sealed_at
          )
        end

        # 新批 admission 原子原语（批次行 + 首个输入同事务）：消除「批次行已建、
        # 输入未落」的崩溃窗口——该窗口会留下孤儿空批并占用 batch_id 序号
        # （下一条同序号 admit 撞批次主键，admission 永久毒化）。
        # 返回 false = 输入 event_id 已存在（主键守卫兜底），事务内已回滚。
        def admit_new_batch(batch : ::Sebas::Sessions::Scheduling::Batch, env : ::Sebas::Sessions::Scheduling::InputEnvelope,
                            position : Int64) : Bool
          inserted = false
          @db.transaction do |tx|
            connection = tx.connection
            connection.exec(
              "INSERT INTO session_batches (batch_id, session_key, status, policy_snapshot, first_seq, last_seq, seal_reason, created_at, sealed_at) " \
              "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
              batch.batch_id, batch.session_key, batch.status.to_s, batch.policy_snapshot.to_json,
              batch.first_seq, batch.last_seq, batch.seal_reason, batch.created_at, batch.sealed_at
            )
            dup_rows = connection.exec(
              "INSERT OR IGNORE INTO session_inputs " \
              "(event_id, session_key, source, sender, received_seq, received_at, source_occurred_at, payload, policy_snapshot, status, batch_id) " \
              "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'batched', ?)",
              env.event_id, env.session_key, env.source, env.sender, env.received_seq,
              env.received_at, env.source_occurred_at, env.payload,
              env.policy_snapshot.to_json, batch.batch_id
            ).rows_affected
            # crystal-db 语义：事务块正常返回即提交，仅异常才回滚——守卫路径必须
            # raise DB::Rollback 显式回滚（否则批次行残留并毒化该 batch_id 序号）
            raise ::DB::Rollback.new unless dup_rows > 0
            inserted = true
            connection.exec(
              "INSERT INTO session_batch_members (event_id, batch_id, position) VALUES (?, ?, ?)",
              env.event_id, batch.batch_id, position
            )
            connection.exec(
              "UPDATE session_batches SET last_seq = MAX(last_seq, ?) WHERE batch_id = ?",
              env.received_seq, batch.batch_id
            )
          end
          inserted
        end

        # 受守卫批次收敛（批次迁移 + 成员输入迁移同一事务）：守卫失败（状态已变）
        # 整组回滚返回 false——陈旧回调/恢复改判不会留下半收敛状态。
        # moves 逐条执行：only 为 nil 迁移全部 from 态成员，否则仅迁移列表内 event_id。
        record MemberMove, from : ::Sebas::Sessions::Scheduling::InputStatus,
          to : ::Sebas::Sessions::Scheduling::InputStatus, only : Array(String)?

        # 私有哨兵：批次守卫失败时中止事务（DB::Transaction 自动回滚）
        private class SettleConflict < ::Exception; end

        def settle_batch(batch_id : String, batch_from : ::Sebas::Sessions::Scheduling::BatchStatus,
                         batch_to : ::Sebas::Sessions::Scheduling::BatchStatus,
                         moves : Array(MemberMove), seal_reason : String? = nil) : Bool
          committed = false
          begin
            @db.transaction do |tx|
              connection = tx.connection
              if seal_reason
                changed = connection.exec(
                  "UPDATE session_batches SET status = ?, seal_reason = ?, sealed_at = ? WHERE batch_id = ? AND status = ?",
                  batch_to.to_s, seal_reason, now, batch_id, batch_from.to_s
                ).rows_affected
              else
                changed = connection.exec(
                  "UPDATE session_batches SET status = ? WHERE batch_id = ? AND status = ?",
                  batch_to.to_s, batch_id, batch_from.to_s
                ).rows_affected
              end
              raise SettleConflict.new("batch #{batch_id} not in #{batch_from}") unless changed > 0
              moves.each do |move|
                if only = move.only
                  only.each do |event_id|
                    connection.exec(
                      "UPDATE session_inputs SET status = ? WHERE event_id = ? AND status = ?",
                      move.to.to_s, event_id, move.from.to_s
                    )
                  end
                else
                  connection.exec(
                    "UPDATE session_inputs SET status = ? WHERE status = ? AND event_id IN " \
                    "(SELECT event_id FROM session_batch_members WHERE batch_id = ?)",
                    move.to.to_s, move.from.to_s, batch_id
                  )
                end
              end
              committed = true
            end
          rescue SettleConflict
          end
          committed
        end

        # 受守卫的状态迁移：WHERE status = from 保证迁移表由调用方（纯函数）裁决，
        # 返回 false = 状态已变（seal/新输入竞态由唯一约束 + 本守卫双保险）
        def transition_session_batch(batch_id : String, from : ::Sebas::Sessions::Scheduling::BatchStatus,
                                     to : ::Sebas::Sessions::Scheduling::BatchStatus, seal_reason : String? = nil) : Bool
          if seal_reason
            changed = @db.exec(
              "UPDATE session_batches SET status = ?, seal_reason = ?, sealed_at = ? WHERE batch_id = ? AND status = ?",
              to.to_s, seal_reason, now, batch_id, from.to_s
            ).rows_affected
          else
            changed = @db.exec(
              "UPDATE session_batches SET status = ? WHERE batch_id = ? AND status = ?",
              to.to_s, batch_id, from.to_s
            ).rows_affected
          end
          changed > 0
        end

        def transition_session_input(event_id : String, from : ::Sebas::Sessions::Scheduling::InputStatus,
                                     to : ::Sebas::Sessions::Scheduling::InputStatus) : Bool
          changed = @db.exec("UPDATE session_inputs SET status = ? WHERE event_id = ? AND status = ?",
            to.to_s, event_id, from.to_s).rows_affected
          changed > 0
        end

        # 批内成员整体迁移（dispatch/done 面）：以 members 关系批量迁移，返回迁移行数
        def transition_batch_inputs(batch_id : String, from : ::Sebas::Sessions::Scheduling::InputStatus,
                                    to : ::Sebas::Sessions::Scheduling::InputStatus) : Int64
          @db.exec(
            "UPDATE session_inputs SET status = ? WHERE status = ? AND event_id IN " \
            "(SELECT event_id FROM session_batch_members WHERE batch_id = ?)",
            to.to_s, from.to_s, batch_id
          ).rows_affected
        end

        # 本会话持久接收序号（契约 §4.2：以本地持久接收序保序，外部时间戳仅元数据）。
        # 同会话 admission 由 SessionScheduler 互斥串行，MAX+1 无竞态。
        def next_session_seq(session_key : String) : Int64
          @db.query_one(
            "SELECT COALESCE(MAX(received_seq), 0) + 1 FROM session_inputs WHERE session_key = ?",
            session_key, as: Int64
          )
        end

        # 会话待发批次（first_seq 序，head dispatch 用）
        def pending_batches(session_key : String) : Array(SessionBatchRow)
          query_batches("status IN ('sealed', 'queued') AND session_key = ?", session_key)
        end

        # 有界容量负载（契约 §6）：会话未完成批次（collecting/sealed/queued）数与成员字节量。
        # bytes 用 CAST BLOB 后 LENGTH 保证 UTF-8 字节口径。
        record PendingLoad, batches : Int64, bytes : Int64

        def pending_load(session_key : String) : PendingLoad
          batches = @db.query_one(
            "SELECT COUNT(*) FROM session_batches WHERE session_key = ? AND status IN ('collecting', 'sealed', 'queued')",
            session_key, as: Int64
          )
          bytes = @db.query_one(
            "SELECT COALESCE(SUM(LENGTH(CAST(i.payload AS BLOB))), 0) FROM session_batch_members m " \
            "JOIN session_inputs i ON i.event_id = m.event_id " \
            "JOIN session_batches b ON b.batch_id = m.batch_id " \
            "WHERE b.session_key = ? AND b.status IN ('collecting', 'sealed', 'queued')",
            session_key, as: Int64
          )
          PendingLoad.new(batches, bytes)
        end

        record SessionBatchRow, batch_id : String, session_key : String, status : String,
          policy_snapshot : String, first_seq : Int64, last_seq : Int64, seal_reason : String?

        record SessionInputRow, event_id : String, session_key : String, source : String,
          sender : String, received_seq : Int64, received_at : String,
          source_occurred_at : String?, payload : String, policy_snapshot : String,
          status : String, batch_id : String?

        record SessionSteerRow, steer_id : String, session_key : String, target_turn_id : String,
          target_generation : Int64, payload : String, status : String, reason : String?,
          created_at : String = "", dispatch_event_id : String? = nil

        private def now : String
          ::Time.utc.to_rfc3339
        end
      end # class Store（闭合迁自切分——SteerStoreMethods 段独立文件）
    end
  end
end
