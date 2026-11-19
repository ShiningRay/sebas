require "../../src/orchestration/triggers/triggers"
require "../../src/orchestration/engine"
require "../../src/tools/executor"
require "../../src/platform/store/store"
require "file_utils"

dir = Path[ENV["TEMP"], "trig-probe-#{Random::Secure.hex(3)}"]
FileUtils.rm_rf(dir)
store = ::Sebas::Platform::Store::Store.new(dir / "db.sqlite")
registry = ::Sebas::Tools::Registry.new
engine = ::Sebas::Orchestration::Engine.new(store, ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new))
wf = ::Sebas::Orchestration::DSL::Workflow.new("probe-wf", "t", true,
  ::Sebas::Orchestration::DSL::Trigger.new("event", "email.*", "email.*"),
  [::Sebas::Orchestration::DSL::Action.new("act", "counter.hit", "{}", "", "", "", 300)])
engine.register(wf)
bus = ::Sebas::Platform::Bus::Bus.new(16)
mgr = ::Sebas::Orchestration::TriggerManager.new(engine, bus)
mgr.start
puts "STARTED running=#{mgr.inspect.includes?("running")}"
bus.publish(::Sebas::Platform::Bus::InboundMessage.new("evt-1", "email", "acc", "peer", "hi"))
puts "PUBLISHED"
10.times do
  sleep 500.milliseconds
  st = store.intent_status("run:probe-wf:evt-1")
  puts "STATUS=#{st.inspect}"
  break if st == "dispatched"
end
mgr.stop
bus.close
store.close
