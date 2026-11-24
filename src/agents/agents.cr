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

      # 目录轨 id 清单（M4.4-WP1 双轨互查用）
      def ids : Array(String)
        @mutex.synchronize { @agents.keys }
      end

      def size : Int32
        @mutex.synchronize { @agents.size }
      end
    end

    # 双轨统一视图（M4.4-WP1）：Config::AgentConfig（YAML 轨）与
    # AgentRegistry（目录/SOUL.md 轨）一致可互查。
    # 存量兼容：目录轨已有 SOUL.md 不强制迁移（config 轨缺失仅列出不报错）。
    class RegistryDualView
      private getter registry : AgentRegistry
      private getter config_agents : Hash(String, ::Sebas::Platform::Config::AgentConfig)

      def initialize(@registry, @config_agents)
      end

      record AgentView, id : String, in_config : Bool, in_registry : Bool,
        persona_file : String?, model : String?

      # 全量互查：每个 agent 的双轨在位情况。config 轨权威（model 必有）；
      # 目录轨缺失 = get_or_create 会建默认 SOUL.md（不强制迁移，只列明）。
      def snapshot : Array(AgentView)
        names = (@config_agents.keys + @registry.ids).uniq.sort
        names.map do |name|
          cfg = @config_agents[name]?
          in_registry = !@registry.get(name).nil?
          AgentView.new(
            id: name,
            in_config: !cfg.nil?,
            in_registry: in_registry,
            persona_file: cfg.try(&.persona_file),
            model: cfg.try(&.model)
          )
        end
      end

      # 幂等补建：config 定义的 agent 在目录轨缺实例时 get_or_create 默认
      # SOUL.md（存量已有 SOUL.md 不覆盖——只读兼容不强制迁移）
      def sync_config_agents : Nil
        @config_agents.keys.each { |name| @registry.get_or_create(name) }
      end

      # 双轨一致：config 定义的 agent 在目录轨均有 SOUL.md 实例（sync 后恒真）
      def consistent_for_config_agents? : Bool
        @config_agents.keys.all? { |name| !@registry.get(name).nil? }
      end
    end
  end
end
