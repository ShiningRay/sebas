require "log"
require "../log"

# Agent 执行池（M0-WP5）：per-session worker 池（design.md §4.3，B3 反向断言）。
# 同会话保序、跨会话并行；全局并发上限经信号量（§8.3），超限进入每会话队列排队
# （不丢弃、不饿死：队列按会话分片）。
module Sebas
  module Agents
    # 会话键含账号维度（§3.3，修复 autobot B4 跨账号撞车）：
    #   session_key = "agent:<agent_id>:<account_id>:<channel_type>:<peer>"
    def self.session_key(agent_id : String, account_id : String, channel_type : String, peer : String) : String
      "agent:#{agent_id}:#{account_id}:#{channel_type}:#{peer}"
    end

    # 计数信号量（buffered Channel 惯用法）：acquire=send（满则阻塞），release=receive
    class Semaphore
      def initialize(slots : Int32)
        raise ArgumentError.new("semaphore slots must be positive") unless slots.positive?
        @channel = Channel(Nil).new(slots)
      end

      def acquire : Nil
        @channel.send(nil)
      end

      def release : Nil
        @channel.receive?
      end
    end

    record Job, session_key : String, payload : String

    class Pool
      Log = Sebas::Log.for("sebas.agents.pool")

      getter session_queue_capacity : Int32
      getter max_concurrency : Int32

      # handler：单个 turn 的执行体（工具循环在 M0-WP6 注入）；异常不得炸进程（typed rescue 转值）
      def initialize(max_concurrency : Int32 = 8, session_queue_capacity : Int32 = 16,
                     &@handler : Job -> Nil)
        raise ArgumentError.new("max_concurrency must be positive") unless max_concurrency.positive?
        @semaphore = Semaphore.new(max_concurrency)
        @max_concurrency = max_concurrency
        @session_queue_capacity = session_queue_capacity
        @queues = {} of String => Channel(Job)
        @mutex = Mutex.new
      end

      # 会话入队：首次入站时按 session_key 分配/复用 worker fiber（§4.3）
      def enqueue(session_key : String, payload : String) : Nil
        queue = queue_for(session_key)
        queue.send(Job.new(session_key, payload)) # 队列满则阻塞（背压可观测）
      end

      # 停机：关闭全部会话队列，worker 清空在途任务后退出
      def shutdown : Nil
        @mutex.synchronize do
          @queues.each_value(&.close)
          @queues.clear
        end
      end

      private def queue_for(session_key : String) : Channel(Job)
        @mutex.synchronize do
          queue = @queues[session_key]?
          return queue if queue
          queue = Channel(Job).new(@session_queue_capacity)
          @queues[session_key] = queue
          spawn_worker(session_key, queue)
          queue
        end
      end

      private def spawn_worker(session_key : String, queue : Channel(Job)) : Nil
        spawn(name: "sebas-worker:#{session_key}") do
          Log.debug { "worker started: #{session_key}" }
          while job = queue.receive?
            @semaphore.acquire
            begin
              @handler.call(job)
            rescue ex
              # 错误转值纪律：单 turn 失败不影响池与其他会话（autobot registry.cr 先例）
              Log.error(exception: ex) { "turn failed in session #{session_key}" }
            ensure
              @semaphore.release
            end
          end
          Log.debug { "worker stopped: #{session_key}" }
        end
      end
    end
  end
end
