require "spec"
require "json"
require "file_utils"
require "../../src/plugins/hook_bus"
require "../../src/plugins/hook_dispatcher"
require "../../src/plugins/manifest"
require "../../src/sessions/lifecycle/lifecycle"
require "../../src/sessions/compaction/compactor"
require "../../src/platform/store/store"

# session.compact.* 生产触发点验收（M3-WP5 review，#287 Linked Issues）：
# archive 路径真实触发 before/after——转写取自 store、摘要落 store
# （role=compaction），hook 经 HookDispatcher 真实派发（非 HookBus.disabled）。
module Sebas
  # 观察型桩：记录派发的 hook 与 payload 键
  class RecordingHookDispatch < ::Sebas::Plugins::Dispatch
    property script : (String, String -> ::Sebas::Plugins::CallOutcome)?

    getter hooks_seen = [] of String

    def initialize
      super(::Sebas::Plugins::Registry.new, ::Sebas::Plugins::Runner.new(["stub"]))
    end

    def call_plugin_for_hook(plugin_id : String, hook : String, context : JSON::Any,
                             payload : JSON::Any, idempotency_key : String? = nil) : ::Sebas::Plugins::CallOutcome
      hooks_seen << hook
      script = @script
      return ::Sebas::Plugins::CallOutcome.success(nil, 0) unless script
      script.call(plugin_id, hook)
    end
  end

  describe "archive 压缩触发点（M3-WP5 生产接线）" do
    it "archive 时真实触发 session.compact.before/after 并落摘要（集成）" do
      dir = Path[Dir.tempdir, "sebas-compact-#{Random::Secure.hex(4)}"]
      Dir.mkdir_p(dir)
      begin
        store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
        lifecycle = ::Sebas::Sessions::Lifecycle::Store.new(store, dir)

        rec = RecordingHookDispatch.new
        dispatcher = ::Sebas::Plugins::HookDispatcher.new
        dispatcher.dispatch = rec
        %w[session.compact.before session.compact.after].each do |hook|
          pid = hook.gsub(".", "-").sub("session-", "")
          manifest = ::Sebas::Plugins::Manifest.parse(%({"schema_version":1,"id":"#{pid}","version":"1.0.0","api_version":"1","hooks":["#{hook}"]}))
          dispatcher.subscribe(hook, manifest, pid)
        end
        bus = ::Sebas::Plugins::HookBus.new(dispatcher)

        compactor = CompactionProbeCompactor.new
        lifecycle.hook_bus = bus
        lifecycle.compaction_runner = ::Sebas::Sessions::Compaction::CompactionRunner.new(bus)
        lifecycle.session_compactor = compactor

        lifecycle.touch("sess-1", "main")
        %w[first message second message third message].in_groups_of(2, "") do |pair|
          store.append_transcript("sess-1", pair[0] || "user", pair[1].to_s)
        end
        store.append_transcript("sess-1", "user", "hello world")
        store.append_transcript("sess-1", "assistant", "hi there")

        lifecycle.archive("sess-1").should be_true

        # before 与 after 都在生产路径真实派发（顺序：before 先于 after）
        rec.hooks_seen.should eq(["session.compact.before", "session.compact.after"])
        compactor.sessions.should eq(["sess-1"])
        # 摘要落转写（role=compaction）
        rows = store.transcripts("sess-1")
        compaction_row = rows.find(&.role.==("compaction"))
        fail("compaction summary row missing") if compaction_row.nil?
        compaction_row.content.should contain("hello world")
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "未装配 compactor 时 archive 不触发 compact hooks（无假 hook 声称生产压缩）" do
      dir = Path[Dir.tempdir, "sebas-compact-#{Random::Secure.hex(4)}"]
      Dir.mkdir_p(dir)
      begin
        store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
        lifecycle = ::Sebas::Sessions::Lifecycle::Store.new(store, dir)
        lifecycle.touch("sess-2", "main")
        store.append_transcript("sess-2", "user", "hello")
        lifecycle.archive("sess-2").should be_true
        # 未装配：无压缩器、无 compact hook（session.end 仍走 disabled bus）
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end

private class CompactionProbeCompactor < ::Sebas::Sessions::Compaction::SessionCompactor
  getter sessions = [] of String

  def compact(session_key : String, transcript : Array(String)) : ::Sebas::Sessions::Compaction::CompactionResult
    @sessions << session_key
    ::Sebas::Sessions::Compaction::CompactionResult.new(transcript.join(" | "), transcript.size * 10, 0)
  end
end
