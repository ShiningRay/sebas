require "spec"
require "file_utils"
require "../../../src/platform/store/store"
require "../../../src/sessions/lifecycle/lifecycle"

def lifecycle_env
  dir = Path[Dir.tempdir, "sebas-lifecycle-spec", Random::Secure.hex(4)]
  FileUtils.mkdir_p(dir)
  store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
  store.append_transcript("agent:main:acc:email:alice@example.com", "user", "hello")
  lifecycle = ::Sebas::Sessions::Lifecycle::Store.new(store)
  {store, lifecycle, dir}
end

module Sebas
  describe "会话生命周期治理（M4.4-WP3，semantics §5 第 9 表）" do
    it "touch 登记会话（upsert：重复 touch 刷新 last_active_at 不重复行）" do
      store, lifecycle, _dir = lifecycle_env
      lifecycle.touch("agent:main:acc:email:alice@example.com", "main", "user")
      lifecycle.touch("agent:main:acc:email:alice@example.com", "main", "user")
      lifecycle.list.size.should eq(1)
      row = lifecycle.get("agent:main:acc:email:alice@example.com").should be_a(::Sebas::Sessions::Lifecycle::SessionRow)
      row = row.as(::Sebas::Sessions::Lifecycle::SessionRow)
      row.status.should eq("active")
      row.kind.should eq("user")
      store.close
    end

    it "休眠阈值：last_active_at 超阈值的 active 会话标 dormant" do
      store, lifecycle, _dir = lifecycle_env
      lifecycle.touch("agent:main:acc:email:old@example.com", "main", "user")
      store.db.exec(
        "UPDATE sessions SET last_active_at = ? WHERE session_key = ?",
        (::Time.utc - 30.days).to_rfc3339, "agent:main:acc:email:old@example.com"
      )
      lifecycle.touch("agent:main:acc:email:fresh@example.com", "main", "user")

      dormant = lifecycle.mark_dormant(older_than_days: 14)
      dormant.should eq(["agent:main:acc:email:old@example.com"])
      old_row = lifecycle.get("agent:main:acc:email:old@example.com")
      old_row = old_row.as(::Sebas::Sessions::Lifecycle::SessionRow)
      old_row.status.should eq("dormant")
      fresh_row = lifecycle.get("agent:main:acc:email:fresh@example.com")
      fresh_row = fresh_row.as(::Sebas::Sessions::Lifecycle::SessionRow)
      fresh_row.status.should eq("active")
      lifecycle.mark_dormant(older_than_days: 14).should be_empty
    end

    it "归档可查不可写 + GC 人工确认导出并清理（不重复回收）" do
      store, lifecycle, dir = lifecycle_env
      key = "agent:main:acc:email:carol@example.com"
      store.append_transcript(key, "user", "to be archived")
      lifecycle.touch(key, "main", "user")

      lifecycle.archive(key).should be_true
      archived_row = lifecycle.get(key)
      archived_row = archived_row.as(::Sebas::Sessions::Lifecycle::SessionRow)
      archived_row.status.should eq("archived")
      lifecycle.archived?(key).should be_true

      archive_dir = dir / "archive"
      cleaned = lifecycle.gc_archived(archive_dir.to_s, archive_confirm: true)
      cleaned.should eq(1)
      store.transcripts(key).should be_empty
      Dir.children(archive_dir).size.should eq(1)
      collected_row = lifecycle.get(key)
      collected_row = collected_row.as(::Sebas::Sessions::Lifecycle::SessionRow)
      collected_row.archived_path.should_not be_nil
      lifecycle.gc_archived(archive_dir.to_s, archive_confirm: true).should eq(0)
      store.close
    end

    it "回收人工确认闸：archive_confirm=false 不清理" do
      store, lifecycle, dir = lifecycle_env
      key = "agent:main:acc:email:dave@example.com"
      store.append_transcript(key, "user", "keep me")
      lifecycle.touch(key, "main", "user")
      lifecycle.archive(key).should be_true

      cleaned = lifecycle.gc_archived((dir / "archive").to_s, archive_confirm: false)
      cleaned.should eq(0)
      store.transcripts(key).size.should eq(1) # 未清理
      store.close
    end

    it "mark_dormant 条件 UPDATE：查改间隙被 touch 刷新的会话不误标" do
      store, lifecycle, _dir = lifecycle_env
      key = "agent:main:acc:email:racy@example.com"
      store.append_transcript(key, "user", "racy touch")
      lifecycle.touch(key, "main", "user")
      store.db.exec(
        "UPDATE sessions SET last_active_at = ? WHERE session_key = ?",
        (::Time.utc - 30.days).to_rfc3339, key
      )

      # 查询出 stale 集、再 touch 刷新（模拟查改间隙竞态），条件 UPDATE 不再命中
      cutoff = (::Time.utc - 14.days).to_rfc3339
      stale = [] of String
      store.db.query(
        "SELECT session_key FROM sessions WHERE status = 'active' AND last_active_at < ?",
        cutoff) do |result_set|
        while result_set.move_next
          stale << result_set.read(String)
        end
      end
      stale.should eq([key])
      lifecycle.touch(key, "main", "user") # 竞态点

      affected = store.db.exec(
        "UPDATE sessions SET status = 'dormant' WHERE session_key = ? AND status = 'active' AND last_active_at < ?",
        key, cutoff).rows_affected
      affected.should eq(0)
      row = lifecycle.get(key).as(::Sebas::Sessions::Lifecycle::SessionRow)
      row.status.should eq("active")
      store.close
    end

    it "gc 目录限定：base_dir 注入后越界目录拒收（不写盘），界内正常" do
      store = ::Sebas::Platform::Store::Store.new(Path[Dir.tempdir, "sebas-lifecycle-spec", Random::Secure.hex(4), "sebas.db"])
      data_dir = Path[Dir.tempdir, "sebas-lifecycle-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(data_dir)
      lifecycle = ::Sebas::Sessions::Lifecycle::Store.new(store, data_dir)
      key = "agent:main:acc:email:erin@example.com"
      store.append_transcript(key, "user", "gc guard")
      lifecycle.touch(key, "main", "user")
      lifecycle.archive(key).should be_true

      outside = Path[Dir.tempdir, "sebas-lifecycle-spec", Random::Secure.hex(4)]
      lifecycle.gc_archived((outside / "evil").to_s, archive_confirm: true).should eq(0)
      Dir.exists?(outside / "evil").should be_false # 越界不写盘

      lifecycle.gc_archived((data_dir / "archive").to_s, archive_confirm: true).should eq(1)
      Dir.children(data_dir / "archive").size.should eq(1)
      store.close
    end
  end
end
