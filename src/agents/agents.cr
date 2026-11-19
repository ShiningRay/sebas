require "file_utils"
require "../log"

# Agent 实例（M3-WP1，design.md §3.1）：人格（SOUL）+记忆目录+工具面独立；
# 无渠道凭据（凭据归 Account，两轴正交）。
# 验收口径：两 agent 各自人格/记忆独立应答。
module Sebas
  module Agents
    class AgentInstance
      getter id : String
      getter persona : String
      getter memory_dir : Path

      def initialize(@id : String, agents_root : String | Path, persona : String? = nil)
        @memory_dir = Path[agents_root, @id]
        FileUtils.mkdir_p(@memory_dir) unless Dir.exists?(@memory_dir)
        soul = @memory_dir / "SOUL.md"
        if persona
          File.write(soul, persona) # 显式人格（测试注入）
        elsif !File.exists?(soul)
          File.write(soul, default_soul(@id))
        end
        @persona = File.read(soul)
      end

      def memory_read(name : String) : String?
        path = @memory_dir / name
        File.exists?(path) ? File.read(path) : nil
      end

      def memory_write(name : String, content : String) : Nil
        File.write(@memory_dir / name, content)
      end

      private def default_soul(id : String) : String
        "# #{id}\n\nYou are agent #{id} of the Sebas personal agent platform.\n"
      end
    end

    class AgentRegistry
      @agents = Hash(String, AgentInstance).new
      @mutex = Mutex.new

      def initialize(agents_root : String | Path)
        @root = Path[agents_root]
        FileUtils.mkdir_p(@root) unless Dir.exists?(@root)
      end

      def get_or_create(id : String, persona : String? = nil) : AgentInstance
        @mutex.synchronize do
          @agents[id]? || begin
            instance = AgentInstance.new(id, @root, persona)
            @agents[id] = instance
            instance
          end
        end
      end

      def get(id : String) : AgentInstance?
        @mutex.synchronize { @agents[id]? }
      end

      def ids : Array(String)
        @mutex.synchronize { @agents.keys }
      end

      def size : Int32
        @mutex.synchronize { @agents.size }
      end
    end
  end
end
