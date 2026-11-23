require "../src/platform/cli/gateway"
require "../src/sessions/scheduling/policy"
require "../src/sessions/scheduling/scheduler"
require "file_utils"

dir = Path[Dir.tempdir, "probe7", Random::Secure.hex(4)]
FileUtils.mkdir_p(dir)
store = ::Sebas::Platform::Store::Store.new(dir / "db.sqlite")
policy = ::Sebas::Sessions::Scheduling::PolicySnapshot.new(
  batch_mode: "debounce", idle_ms: 0_i64, max_wait_ms: 5000_i64,
  max_messages: 20_i64, max_bytes: 32768_i64, flush_on_turn_end: false,
  group_by: "sender", max_active_buckets: 32_i64,
  max_pending_batches: 32_i64, max_pending_bytes: 262144_i64,
  steer_enabled: false, steer_debounce_ms: 300_i64,
  steer_max_pending_messages: 16_i64, steer_max_wait_ms: 30000_i64)
scheduler = ::Sebas::Sessions::Scheduling::SessionScheduler.new(
  "agent:main:a:email:x", store, ->(key : String, payload : String) { nil },
  clock: -> { 1_000_000_i64 })
env1 = ::Sebas::Sessions::Scheduling::InputEnvelope.new(
  "e-b1", "agent:main:a:email:x", "email", "alice", 0,
  ::Time.utc.to_rfc3339, nil, "x" * 20000, policy)
r1 = scheduler.admit(env1)
p [r1.status, r1.batch_id]
p "after1: " + store.pending_batches("agent:main:a:email:x").map(&.seal_reason).join(",")
env2 = ::Sebas::Sessions::Scheduling::InputEnvelope.new(
  "e-b2", "agent:main:a:email:x", "email", "alice", 0,
  ::Time.utc.to_rfc3339, nil, "x" * 20000, policy)
r2 = scheduler.admit(env2)
p [r2.status, r2.batch_id]
p "after2: " + store.pending_batches("agent:main:a:email:x").map { |b| "#{b.batch_id}=#{b.status}:#{b.seal_reason}" }.join(",")
