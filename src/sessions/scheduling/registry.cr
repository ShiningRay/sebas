# frozen_string_literal: true

require "log"
require "../../log"
require "./envelope"
require "./scheduler"

module Sebas
  module Sessions
    module Scheduling
      class Registry
        Log = Sebas::Log.for("sebas.scheduling.registry")

        @mutex = Mutex.new
        @schedulers = {} of String => SessionScheduler
        @dispatch_handler : SessionScheduler::DispatchFn? = nil

        def initialize(@store : ::Sebas::Platform::Store::Store)
        end

        # 装配接线（gateway initialize 在 build_pool 之后调用）
        def dispatch_handler=(fn : SessionScheduler::DispatchFn) : Nil
          @dispatch_handler = fn
        end

        def admit(env : InputEnvelope) : AdmissionReceipt
          scheduler_for(env.session_key).admit(env)
        end

        def batch_done(session_key : String, batch_id : String, failed_event_ids : Array(String) = [] of String) : Nil
          scheduler_for(session_key).batch_done(batch_id, failed_event_ids)
        end

        def batch_crashed(session_key : String, batch_id : String) : Nil
          scheduler_for(session_key).batch_crashed(batch_id)
        end

        # 启动重派：对有持久待发批次的会话逐个 kick（空闲守卫在 scheduler 内）
        def recover_dispatch : Int32
          sessions = @store.recoverable_batches.map(&.session_key)
          sessions.uniq!
          sessions.each { |session_key| scheduler_for(session_key).dispatch_if_idle }
          sessions.size
        end

        def shutdown : Nil
          @mutex.synchronize { @schedulers.each_value(&.shutdown) }
        end

        # seal 扫描转发：对所有 scheduler 执行 seal_due（定时器调用入口，#5）
        def seal_due(now_ms : Int64? = nil) : Int32
          total = 0
          @mutex.synchronize { @schedulers.each_value { |scheduler| total += scheduler.seal_due(now_ms) } }
          total
        end

        # 测试/观测面：指定会话的 scheduler（不存在则 nil）
        def scheduler?(session_key : String) : SessionScheduler?
          @mutex.synchronize { @schedulers[session_key]? }
        end

        private def scheduler_for(session_key : String) : SessionScheduler
          @mutex.synchronize do
            @schedulers[session_key] ||= SessionScheduler.new(session_key, @store,
              ->(key : String, payload : String) { dispatch_to_pool(key, payload) })
          end
        end

        private def dispatch_to_pool(session_key : String, payload : String) : Nil
          handler = @dispatch_handler
          raise "scheduling dispatch handler not wired (registry assembled before pool)" unless handler
          handler.call(session_key, payload)
        end
      end
    end
  end
end
