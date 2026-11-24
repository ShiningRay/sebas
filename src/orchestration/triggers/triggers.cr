require "json"
require "../../platform/bus/bus"
require "../../platform/store/store"
require "../engine"
require "../dsl/dsl"
require "./cron"
require "../../log"

# 触发器统一（M2-WP3，design.md §7.1）：cron/消息事件/账号事件/webhook 归一为
# 触发源 → engine.start(workflow, trigger_event_id)。
# A10 改造点：cron owner 加账号维度——cron key = agent:workflow，投递经 run intent 幂等。
module Sebas
  module Orchestration
    class TriggerManager
      Log = Sebas::Log.for("sebas.orchestration.triggers")

      record CronJob, agent_id : String, workflow_id : String, expr : String, next_at : Time

      @cron_jobs = Hash(String, CronJob).new
      @webhook_names = Set(String).new
      @mutex = Mutex.new
      @running = Atomic(Bool).new(false)

      def initialize(@engine : Engine, @bus : ::Sebas::Platform::Bus::Bus)
      end

      # 从注册的 workflows 装载触发源
      def load_from_registry : Nil
        @engine.workflows.each_value do |workflow|
          case workflow.trigger.type
          when "cron"
            next_at = Cron.next_after(workflow.trigger.schedule)
            register_cron(workflow.id, "main", workflow.trigger.schedule, next_at)
          when "webhook"
            @mutex.synchronize { @webhook_names << workflow.trigger.source }
          end
        end
      end

      def register_cron(workflow_id : String, agent_id : String, expr : String, next_at : Time) : Nil
        @mutex.synchronize do
          # 已注入（如测试注入到期时间/恢复现场）不覆盖
          next if @cron_jobs.has_key?(workflow_id)
          @cron_jobs[workflow_id] = CronJob.new(agent_id, workflow_id, expr, next_at)
        end
        Log.info { "cron registered: #{workflow_id} (#{expr}) next=#{next_at}" }
      end

      def webhook?(name : String) : Bool
        @mutex.synchronize { @webhook_names.includes?(name) }
      end

      # 外部 webhook 唤醒（§9.2 POST /hooks/<name>；HTTP admin 调用）。
      # event_id 优先取外部 Idempotency-Key 派生值（重试幂等，M4.5-WP5）；
      # 缺省用明确的服务端一次接收 ID——不宣称跨重试去重（原 SHA1+时间戳
      # 每次重试生成新 id，非幂等语义移除）
      def fire_webhook(name : String, payload : String, event_id : String? = nil) : Bool
        wf_id = nil
        @mutex.synchronize do
          next unless @webhook_names.includes?(name)
          wf_id = @engine.workflows.values.find { |workflow| workflow.trigger.type == "webhook" && workflow.trigger.source == name }.try(&.id)
        end
        return false unless wf_id
        final_event = event_id || "webhook:#{name}:recv-#{::Random::Secure.hex(8)}"
        @engine.start(@engine.workflows[wf_id], final_event) != nil
      end

      # 消息/账号事件触发：bus 消费循环调用；source 与事件形状匹配（通配尾段）
      def match_event(source : String, channel_type : String, event_kind : String) : Bool
        return false unless source.present?
        return true if source == "*"
        return true if source == "#{channel_type}.#{event_kind}"
        return true if source.starts_with?(channel_type + ".") && source.ends_with?("*")
        false
      end

      # bus 消费循环（主循环挂入 gateway）
      def start : Nil
        return if @running.swap(true)
        load_from_registry
        spawn(name: "sebas-triggers-cron") { cron_loop }
        spawn(name: "sebas-triggers-bus") { bus_loop }
      end

      def stop : Nil
        @running.set(false)
      end

      # cron 循环：到期 → engine.start（intent 幂等防重）→ 重排下一轮
      private def cron_loop : Nil
        while @running.get
          now = Time.utc
          due_job : CronJob? = nil
          @mutex.synchronize do
            @cron_jobs.each_value do |job|
              if job.next_at <= now
                due_job = job
                break
              end
            end
          end
          if job = due_job
            workflow = @engine.workflows[job.workflow_id]?
            if workflow
              event_id = "cron:#{job.workflow_id}:#{job.next_at.to_unix_ms}" # owner 维度（A10）：agent/workflow/slot
              Log.info { "cron fired: #{job.workflow_id}" }
              @engine.start(workflow, event_id)
            end
            next_at = begin
              Cron.next_after(job.expr, now)
            rescue ex : Cron::CronError
              Log.error { "cron #{job.workflow_id} unreschedulable: #{ex.message}" }
              now + 1.day
            end
            @mutex.synchronize { @cron_jobs[job.workflow_id] = CronJob.new(job.agent_id, job.workflow_id, job.expr, next_at) }
            next
          end
          sleep 1.second # 扫描粒度：分钟级 cron 足够，等待窗口友好
        end
      end

      private def bus_loop : Nil
        while @running.get
          event = @bus.receive?
          break if event.nil?
          case event
          when ::Sebas::Platform::Bus::InboundMessage
            @engine.workflows.each_value do |workflow|
              next unless workflow.trigger.type == "event"
              next unless match_event(workflow.trigger.source, event.channel_type, "message.received")
              @engine.start(workflow, event.event_id)
            end
          when ::Sebas::Platform::Bus::AccountEvent
            @engine.workflows.each_value do |workflow|
              next unless workflow.trigger.type == "account"
              next unless workflow.trigger.source == event.kind || workflow.trigger.source == "*"
              @engine.start(workflow, event.event_id)
            end
          end
        end
      end
    end
  end
end
