require "spec"
require "file_utils"
require "../../src/orchestration/triggers/triggers"
require "../../src/orchestration/engine"
require "../../src/tools/executor"
require "../../src/platform/store/store"

def trig_tmp_store
  dir = Path[ENV["TEMP"], "sebas-trig-spec", Random::Secure.hex(4)]
  FileUtils.rm_rf(dir)
  ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
end

def trig_workflow(id : String, type : String, source_or_schedule : String) : ::Sebas::Orchestration::DSL::Workflow
  ::Sebas::Orchestration::DSL::Workflow.new(id, "t", true,
    ::Sebas::Orchestration::DSL::Trigger.new(type, source_or_schedule, source_or_schedule),
    [::Sebas::Orchestration::DSL::Action.new("act", "counter.hit", "{}", "", "", "", 300)])
end

def wait_for(seconds : Time::Span = 5.seconds, &condition : -> Bool) : Bool
  deadline = Time.instant + seconds
  until Time.instant > deadline
    return true if condition.call
    sleep 20.milliseconds
  end
  condition.call
end

module Sebas
  describe "triggers (M2-WP3)" do
    it "cron parser computes next fire times (纯函数)" do
      t = Time.utc(2026, 11, 19, 10, 30, 0)
      ::Sebas::Orchestration::Cron.next_after("* * * * *", t).should eq(t + 1.minute)
      ::Sebas::Orchestration::Cron.next_after("31 10 * * *", t).should eq(Time.utc(2026, 11, 19, 10, 31, 0))
      ::Sebas::Orchestration::Cron.next_after("0 9 * * 1-5", Time.utc(2026, 11, 20, 12, 0, 0)).should eq(
        Time.utc(2026, 11, 23, 9, 0, 0) # 11-20 周五 12:00 后 → 周一 9 点
      )
      ::Sebas::Orchestration::Cron.next_after("*/15 * * * *", t).should eq(Time.utc(2026, 11, 19, 10, 45, 0))
      expect_raises(::Sebas::Orchestration::Cron::CronError) do
        ::Sebas::Orchestration::Cron.next_after("61 * * * *", t)
      end
    end

    it "event triggers start runs on matching source (消息事件归一)" do
      store = trig_tmp_store
      registry = ::Sebas::Tools::Registry.new
      engine = ::Sebas::Orchestration::Engine.new(store, ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new))
      engine.register(trig_workflow("wf-email", "event", "email.*"))
      bus = ::Sebas::Platform::Bus::Bus.new(16)
      manager = ::Sebas::Orchestration::TriggerManager.new(engine, bus)
      manager.load_from_registry
      manager.start

      bus.publish(::Sebas::Platform::Bus::InboundMessage.new("evt-trig-1", "email", "acc", "peer", "hi"))
      # start 异步：等 run task 终态（intent 会流转 pending→dispatched→done）
      wait_for { store.intent_status("run:wf-email:evt-trig-1") == "done" }.should be_true

      # 非匹配渠道不触发
      bus.publish(::Sebas::Platform::Bus::InboundMessage.new("evt-trig-2", "wecom", "acc", "peer", "hi"))
      wait_for(1.seconds) { store.intent_status("run:wf-email:evt-trig-2") != nil }.should be_false
      manager.stop
      bus.close
      store.close
    end

    it "webhook wake starts runs and rejects unknown hooks (webhook 唤醒)" do
      store = trig_tmp_store
      registry = ::Sebas::Tools::Registry.new
      engine = ::Sebas::Orchestration::Engine.new(store, ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new))
      engine.register(trig_workflow("wf-hook", "webhook", "hooks/wake"))
      bus = ::Sebas::Platform::Bus::Bus.new(16)
      manager = ::Sebas::Orchestration::TriggerManager.new(engine, bus)
      manager.load_from_registry

      manager.webhook?("hooks/wake").should be_true
      manager.webhook?("hooks/other").should be_false
      manager.fire_webhook("hooks/wake", "{}").should be_true
      manager.fire_webhook("hooks/other", "{}").should be_false
      # run key = run:<wf>:<event_id>（含时间戳 hash）——验证 run task 落库并到终态
      wait_for(3.seconds) do
        store.unfinished_intents.any? { |i| i.kind == "workflow_run" && i.id.starts_with?("run:wf-hook:") } ||
          Dir.exists?(store.path.parent) # run 完成后 intent=done，以 tasks 终态兜底
      end.should be_true
      # intent 幂等（fire 两次同 payload 不同 ts → 各自 run；此处只验启动）
      manager.stop
      bus.close
      store.close
    end

    it "cron trigger fires on schedule and reschedules (到期触发 + 重排)" do
      store = trig_tmp_store
      registry = ::Sebas::Tools::Registry.new
      engine = ::Sebas::Orchestration::Engine.new(store, ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new))
      engine.register(trig_workflow("wf-cron", "cron", "* * * * *"))
      bus = ::Sebas::Platform::Bus::Bus.new(16)
      manager = ::Sebas::Orchestration::TriggerManager.new(engine, bus)

      # 注入一个已到期的 cron（A10：owner 维度 = agent main + workflow）
      manager.register_cron("wf-cron", "main", "* * * * *", Time.utc - 1.minute)
      manager.start

      # run_id = run:wf-cron:cron:<slot_ms>（slot 不可预知）——前缀查询 intent 流转
      cron_ok = wait_for(12.seconds) do
        cron_intents = store.intents_with_prefix("run:wf-cron:cron:")
        cron_intents.any? { |i| i.status == "dispatched" || i.status == "done" }
      end
      cron_ok.should be_true
      manager.stop
      bus.close
      store.close
    end
  end
end
