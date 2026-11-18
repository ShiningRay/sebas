# 渠道适配器注册表（M0-WP6）：(渠道类型, 账号) → adapter 实例。
# 路由出站动作按 design.md §3.2：动作显式指定 (channel, account, peer)；未指定账号走默认账号。
module Sebas
  module Channels
    class Registry
      @adapters = Hash(Tuple(String, String), ChannelAdapter).new
      @mutex = Mutex.new

      def register(adapter : ChannelAdapter) : Nil
        @mutex.synchronize { @adapters[{adapter.channel_type, adapter.account_id}] = adapter }
      end

      def remove(channel_type : String, account_id : String) : Nil
        @mutex.synchronize { @adapters.delete({channel_type, account_id}) }
      end

      def find(channel_type : String, account_id : String) : ChannelAdapter?
        @mutex.synchronize { @adapters[{channel_type, account_id}]? }
      end

      # 出站账号解析：显式账号 → 该渠道默认账号（首个注册，OpenClaw 出站默认规则）
      def resolve(channel_type : String, account_id : String?) : ChannelAdapter?
        if account_id && account_id != "*"
          find(channel_type, account_id)
        else
          @mutex.synchronize do
            @adapters.find { |(key, _)| key[0] == channel_type }.try(&.[1])
          end
        end
      end

      def all : Array(ChannelAdapter)
        @mutex.synchronize { @adapters.values }
      end

      def start_all : Nil
        all.each(&.start)
      end

      def stop_all : Nil
        all.each(&.stop)
      end
    end
  end
end
