# 事件总线（M0-WP5）：有界 Channel，事件显式携带账号上下文（design.md §4.1，B3 反向断言：
# 无全局单 Loop；autobot B4 教训——事件从 day one 带账号维度）
require "json"

module Sebas
  module Platform
    module Bus
      # 入站消息事件：requestId = 渠道侧事件 ID（幂等三件套提交级，§7.3）
      # message_id（M3-WP7 扩展点定稿，m8 提案 §4.1）：渠道侧消息定位 ID
      # （Telegram 的 message.message_id 等）。尾置默认 nil——旧适配器五参构造零改动。
      record InboundMessage,
        event_id : String,
        channel_type : String,
        account_id : String,
        peer : String,
        content : String,
        message_id : String? = nil do
        include ::JSON::Serializable
      end

      # 账号生命周期事件（连接断开/恢复、token 失效等，§7.1 触发源之一；M1 起填充）
      record AccountEvent,
        event_id : String,
        channel_type : String,
        account_id : String,
        kind : String do
        include ::JSON::Serializable
      end

      # 事件联合（autobot bus/events.cr:122 先例：union alias + case/in 分派）
      alias Event = InboundMessage | AccountEvent

      class Bus
        getter capacity : Int32

        @channel : Channel(Event)

        def initialize(capacity : Int32 = 100)
          raise ArgumentError.new("bus capacity must be positive") unless capacity.positive?
          @capacity = capacity
          @channel = Channel(Event).new(capacity)
        end

        # 满时 send 阻塞 = 协作式背压（§4.2：buffered Channel，无需锁）
        def publish(event : Event) : Nil
          @channel.send(event)
        end

        def receive : Event
          @channel.receive
        end

        # 消费循环可停机（select + timeout 先例：autobot bus/queue.cr:32-43）
        def receive?(timeout : Time::Span? = nil) : Event?
          if timeout
            select
            when event = @channel.receive
              event
            when timeout timeout
              nil
            end
          else
            @channel.receive?
          end
        end

        def close : Nil
          @channel.close
        end
      end
    end
  end
end
