require "./providers"

# Provider 实例池（A1 改造点）：每 agent 绑定一个 Provider 实例；M1-WP8 的
# provider key 热换 = 池内替换（design.md §4.1 Provider 层）
module Sebas
  module Providers
    class Pool
      @instances = {} of String => Provider
      @mutex = Mutex.new

      # 取该 agent 的 Provider 实例（不存在则按工厂创建并缓存）
      def for_agent(agent_id : String, &factory : -> Provider) : Provider
        @mutex.synchronize do
          instance = @instances[agent_id]?
          return instance if instance
          instance = factory.call
          @instances[agent_id] = instance
          instance
        end
      end

      # 热换入口（M1-WP8）：替换 agent 的 Provider 实例，下个 turn 生效
      def replace(agent_id : String, provider : Provider) : Nil
        @mutex.synchronize { @instances[agent_id] = provider }
      end

      def remove(agent_id : String) : Nil
        @mutex.synchronize { @instances.delete(agent_id) }
      end

      def size : Int32
        @mutex.synchronize { @instances.size }
      end
    end
  end
end
