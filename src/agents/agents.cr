require "file_utils"
require "../log"
require "../platform/config/schema" # config_agents 双视图引用 AgentConfig（显式声明依赖）

# Agent 实例（M3-WP1，design.md §3.1）：人格（SOUL）+记忆目录+工具面独立；
# 无渠道凭据（凭据归 Account，两轴正交）。
# 验收口径：两 agent 各自人格/记忆独立应答。
module Sebas
  module Agents
    class RegistryError < ::Exception; end

    class AgentInstance
      getter id : String
      getter persona : String
      getter memory_dir : Path
      # 管理面元数据（M4x-WP2，#148）：registry 首建时固化，热更新后已存在实例
      # 不自动刷新（避免运行中会话人格/标签漂移）；管理面查询以配置为真相源
      getter category : String?
      getter tags : Array(String)

      # clone_from_template patch 后重读 SOUL.md（patch 落盘→内存一致）
      def reload_persona : Nil
        @persona = File.read(@memory_dir / "SOUL.md")
      end

      def initialize(@id : String, agents_root : String | Path, persona : String? = nil,
                     @category : String? = nil, tags : Array(String) = [] of String)
        @tags = tags.dup # 防御性拷贝：外部后续改动不渗入实例
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

      # category/tags 只在首建时固化进实例（#148）；已存在实例不刷新——
      # `@agents[id]? ||` 短路返回，后续调用传新元数据无效（热更新语义见
      # RegistryDualView 与 IPC agents.list：查询以配置为真相源）。
      def get_or_create(id : String, persona : String? = nil, category : String? = nil,
                        tags : Array(String) = [] of String) : AgentInstance
        @mutex.synchronize do
          @agents[id]? || begin
            instance = AgentInstance.new(id, @root, persona, category, tags)
            @agents[id] = instance
            instance
          end
        end
      end

      # 从模板克隆 agent 一次成型（M4.4-WP2，Q 裁断）：复制模板目录全部
      # 文件（SOUL.md/记忆文件）到新 agent 目录 + 人格 patch（覆盖 SOUL.md
      # 的 persona 段——patch 为空则沿用模板人格）。模板不存在报错可读。
      # 新实例进内存注册（后续 get_or_create 幂等命中）。
      def clone_from_template(template_id : String, new_id : String,
                              persona_patch : String? = nil) : AgentInstance
        template_dir = @root / template_id
        raise ::Sebas::Agents::RegistryError.new(
          "template agent not found: #{template_id} (#{template_dir})") unless Dir.exists?(template_dir)
        new_dir = @root / new_id
        raise ::Sebas::Agents::RegistryError.new(
          "agent already exists: #{new_id} (#{new_dir})") if Dir.exists?(new_dir)
        begin
          FileUtils.cp_r(template_dir, new_dir)
          instance = get_or_create(new_id)
          if patch = persona_patch
            instance.memory_write("SOUL.md", instance.persona + "\n\n## Persona Patch\n\n" + patch)
            instance.reload_persona
          end
          instance
        rescue ex
          # 失败回滚（CodeRabbit J-Bq）：清目标目录 + 注册表，同参数重试可达
          FileUtils.rm_rf(new_dir)
          @mutex.synchronize { @agents.delete(new_id) }
          raise ex
        end
      end

      def get(id : String) : AgentInstance?
        @mutex.synchronize { @agents[id]? }
      end

      # 目录轨 id 清单（M4.4-WP1 双轨互查用）：内存实例 + 磁盘存量目录
      # （SOUL.md 已落盘但本次进程未 get_or_create 的存量 agent——只读可见）
      def ids : Array(String)
        memory_ids = @mutex.synchronize { @agents.keys }
        combined = memory_ids + disk_ids
        combined.uniq!
        combined.sort
      end

      def size : Int32
        ids.size
      end

      # 磁盘存量发现：agents_root 下含 SOUL.md 的子目录即存量 agent
      # （只读可见，不强制加载——get_or_create 时才实例化）
      def disk_ids : Array(String)
        return [] of String unless Dir.exists?(@root)
        disk_ids = Dir.children(@root).select do |entry|
          dir_path = @root / entry
          File.directory?(dir_path) && File.exists?(dir_path / "SOUL.md")
        end
        disk_ids.sort!
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
        names = @config_agents.keys + @registry.ids
        names.uniq!
        names.sort
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
