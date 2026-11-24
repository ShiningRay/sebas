# frozen_string_literal: true

require "json"
require "file_utils"

# 会话生命周期治理（M4.4-WP3，Q8 拆分第二块；提案 M4 门槛）：
# sessions 元数据表（store 第 9 表）+ 状态机 active/dormant/archived +
# 休眠阈值 + 归档命令 + 回收 GC（人工确认非自动删）。
# 不绑 compaction（design.md §6.1 未实现，M4.4 裁断：不等、不绑）。
module Sebas
  module Sessions
    module Lifecycle
      Log = ::Sebas::Log.for("sebas.sessions.lifecycle")

      record SessionRow, session_key : String, agent_id : String, kind : String,
        fork_id : String?, status : String, last_active_at : String,
        created_at : String, archived_path : String?

      DEFAULT_DORMANT_DAYS = 14

      class LifecycleError < ::Exception; end

      # 状态机：active → dormant（超阈值）→ archived（人工确认）；archived
      # 可查不可写（transcripts 只读保留，写路径拒绝）；回收 = 归档会话
      # 的 transcripts 导出 archived_path 后删除（人工确认参数显式开启）。
      STATUSES = %w[active dormant archived]

      class Store
        def initialize(@store : ::Sebas::Platform::Store::Store, @base_dir : Path? = nil)
        end

        # upsert：admission 时登记/刷新 last_active_at（status 不回退）
        def touch(session_key : String, agent_id : String, kind : String = "user",
                  fork_id : String? = nil) : Nil
          now = ::Time.utc.to_rfc3339
          @store.db.exec(
            "INSERT INTO sessions (session_key, agent_id, kind, fork_id, status, last_active_at, created_at) " \
            "VALUES (?, ?, ?, ?, 'active', ?, ?) " \
            "ON CONFLICT(session_key) DO UPDATE SET last_active_at = excluded.last_active_at, " \
            "agent_id = excluded.agent_id, kind = excluded.kind, " \
            "fork_id = COALESCE(excluded.fork_id, sessions.fork_id)",
            session_key, agent_id, kind, fork_id, now, now
          )
        end

        def get(session_key : String) : SessionRow?
          @store.db.query_one?(
            "SELECT session_key, agent_id, kind, fork_id, status, last_active_at, created_at, archived_path " \
            "FROM sessions WHERE session_key = ?", session_key) do |result_set|
            SessionRow.new(
              result_set.read(String), result_set.read(String), result_set.read(String),
              result_set.read(String?), result_set.read(String), result_set.read(String),
              result_set.read(String), result_set.read(String?)
            )
          end
        end

        def list(status : String? = nil) : Array(SessionRow)
          rows = [] of SessionRow
          if status
            @store.db.query(
              "SELECT session_key, agent_id, kind, fork_id, status, last_active_at, created_at, archived_path " \
              "FROM sessions WHERE status = ? ORDER BY last_active_at DESC", status) do |result_set|
              result_set.each do
                rows << SessionRow.new(
                  result_set.read(String), result_set.read(String), result_set.read(String),
                  result_set.read(String?), result_set.read(String), result_set.read(String),
                  result_set.read(String), result_set.read(String?)
                )
              end
            end
          else
            @store.db.query(
              "SELECT session_key, agent_id, kind, fork_id, status, last_active_at, created_at, archived_path " \
              "FROM sessions ORDER BY last_active_at DESC") do |result_set|
              result_set.each do
                rows << SessionRow.new(
                  result_set.read(String), result_set.read(String), result_set.read(String),
                  result_set.read(String?), result_set.read(String), result_set.read(String),
                  result_set.read(String), result_set.read(String?)
                )
              end
            end
          end
          rows
        end

        # 休眠判定：last_active_at 距今超阈值天数 → dormant（仅 active 可休眠）
        def mark_dormant(older_than_days : Int32 = DEFAULT_DORMANT_DAYS) : Array(String)
          cutoff = (::Time.utc - older_than_days.days).to_rfc3339
          dormant = [] of String
          @store.db.query(
            "SELECT session_key FROM sessions WHERE status = 'active' AND last_active_at < ?",
            cutoff) do |result_set|
            while result_set.move_next
              dormant << result_set.read(String)
            end
          end
          # 条件 UPDATE 原子化查改（查与写间 touch 刷新 last_active_at 的会话不误标）
          dormant.select! do |key|
            @store.db.exec(
              "UPDATE sessions SET status = 'dormant' WHERE session_key = ? AND status = 'active' AND last_active_at < ?",
              key, cutoff).rows_affected > 0
          end
          dormant
        end

        # 归档（人工确认由调用方/admin 命令承担）：dormant/active → archived
        def archive(session_key : String) : Bool
          @store.db.exec(
            "UPDATE sessions SET status = 'archived' WHERE session_key = ? AND status != 'archived'",
            session_key).rows_affected > 0
        end

        # 写路径拒绝：archived 会话不可写（append_transcript 前置检查用）
        def archived?(session_key : String) : Bool
          row = get(session_key)
          row.try(&.status) == "archived"
        end

        # 回收 GC（人工确认 archive_confirm=true 才执行；非自动删）：
        # 归档会话 transcripts 导出 JSON 后删除行（单事务：标记+删除原子，
        # 防 archived_path 已写而 transcripts 残留），返回清理数。
        # 导出序列化用 JSON.build（inspect 产生 Crystal 字面量非合法 JSON）；
        # 导出文件名中的非法字符（含 Windows 禁用的 :）替换为 _。
        def gc_archived(archive_dir : String, archive_confirm : Bool) : Int32
          return 0 unless archive_confirm
          # 目录限定：base_dir 注入时，归档目录解析后必须落在其下（防 ../ 逃逸）
          archive_base = @base_dir
          dir = if archive_base
                  resolved = Path[archive_dir].expand(archive_base)
                  # 分隔符归一（Windows 反斜杠）：前缀比较跨平台一致
                  base_s = archive_base.to_s.gsub("\\", "/").chomp('/')
                  resolved_s = resolved.to_s.gsub("\\", "/")
                  return 0 unless resolved_s == base_s || resolved_s.starts_with?(base_s + "/")
                  resolved
                else
                  Path[archive_dir]
                end
          FileUtils.mkdir_p(dir) unless Dir.exists?(dir)
          cleaned = 0
          list("archived").each do |row|
            next if row.archived_path # 已回收过（调用开始时快照判重）
            safe_name = row.session_key.gsub(/[^a-zA-Z0-9._-]/, "_")
            export_path = Path[dir, "#{safe_name}-#{::Random::Secure.hex(4)}.json"]
            tmp_path = Path[dir, ".tmp-#{::Random::Secure.hex(6)}.json"]
            begin
              # 导出先行（JSON.build 产生合法 JSON；temp 名唯一防并发互踩）
              File.open(tmp_path, "w") do |file|
                JSON.build(file) do |json|
                  json.array do
                    @store.transcripts(row.session_key).each do |entry|
                      json.object do
                        json.field("created_at", entry.created_at)
                        json.field("role", entry.role)
                        json.field("content", entry.content)
                      end
                    end
                  end
                end
              end
              # 单事务三步（CodeRabbit Lat3/Latx）：①事务内重读 status 守卫
              # （重叠调用已把它归档/回收时跳过，防覆盖他人 archived_path）；
              # ②rename 原子发布导出文件（发布失败抛错→事务回滚，transcripts
              # 不丢）；③发布成功后才 DELETE transcripts + 标记 archived_path。
              @store.db.transaction do |tx|
                status = tx.connection.query_one?(
                  "SELECT status FROM sessions WHERE session_key = ?", row.session_key,
                  &.read(String)
                )
                next if status != "archived"
                File.rename(tmp_path, export_path) # 发布（同目录 rename 原子）
                tx.connection.exec("DELETE FROM transcripts WHERE session_key = ?", row.session_key)
                tx.connection.exec(
                  "UPDATE sessions SET archived_path = ? WHERE session_key = ?",
                  export_path.to_s, row.session_key
                )
              end
              cleaned += 1
              Log.info { "archived session collected: #{row.session_key} -> #{export_path}" }
            rescue ex : ::Exception
              File.delete(tmp_path) if File.exists?(tmp_path)
              # 失败保留 archived 行与 transcripts（下次 GC 重试）；不吞异常上抛中断其余行
              Log.error(exception: ex) { "archived session collect failed (kept for retry): #{row.session_key}" }
            end
          end
          cleaned
        end
      end
    end
  end
end
