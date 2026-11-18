require "./providers"

# FakeProvider：确定性测试/端到端演练用 Provider（M0-WP5/WP8；不触网）
module Sebas
  module Providers
    class FakeProvider < Provider
      property delay : Time::Span = Time::Span.zero

      # 回复脚本：按调用次序返回；耗尽后回声最后一轮用户消息
      def initialize(@model : String = "fake/chat", @script : Array(String) = [] of String)
        super(@model)
        @cursor = 0
        @mutex = Mutex.new
      end

      def complete(messages : Array(Message)) : Completion
        sleep @delay unless @delay.total_nanoseconds.zero?
        @mutex.synchronize do
          if @cursor < @script.size
            text = @script[@cursor]
            @cursor += 1
            Completion.new(text, nil)
          else
            last_user = messages.reverse_each.find(&.role.==("user"))
            Completion.new("echo: #{last_user.try(&.content) || ""}", nil)
          end
        end
      end
    end
  end
end
