require "spec"
require "file_utils"
require "../../src/agents/agents"
require "../../src/platform/config/schema"
require "../../src/agents/skills/skills"

def skill_dir(name : String, frontmatter : String, body : String) : Path
  dir = Path[Dir.tempdir, "sebas-skill-role-spec", "#{name}-#{Random::Secure.hex(4)}", name]
  FileUtils.mkdir_p(dir)
  File.write(dir / "SKILL.md", "---\n#{frontmatter}\n---\n#{body}")
  dir.parent
end

module Sebas
  describe "Agent 模板克隆（M4.4-WP2）" do
    it "clone_from_template：目录克隆 + 人格 patch 一次成型" do
      dir = Path[Dir.tempdir, "sebas-template-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir / "agents")
      registry = ::Sebas::Agents::AgentRegistry.new(dir / "agents")
      # 模板 agent 建档（SOUL.md + 记忆文件）
      template = registry.get_or_create("research-template")
      template.memory_write("MEMORY.md", "template memory")
      template.persona.should contain("research-template")

      # 克隆 + patch 一次成型
      clone = registry.clone_from_template("research-template", "research-alpha",
        persona_patch: "You specialize in fast research sprints.")
      clone.id.should eq("research-alpha")
      clone.persona.should contain("research-template")           # 模板人格基底（patch 为追加段）
      clone.persona.should contain("Persona Patch")               # patch 段
      clone.persona.should contain("fast research sprints")       # patch 内容
      clone.memory_read("MEMORY.md").should eq("template memory") # 目录克隆

      # 幂等：克隆后 get_or_create 命中同一实例
      again = registry.get_or_create("research-alpha")
      again.persona.should eq(clone.persona)
      # 模板不受影响
      template.memory_read("MEMORY.md").should eq("template memory")
    end

    it "模板不存在 / 目标已存在：报错可读（RegistryError）" do
      dir = Path[Dir.tempdir, "sebas-template-spec2", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir / "agents")
      registry = ::Sebas::Agents::AgentRegistry.new(dir / "agents")
      registry.get_or_create("existing")

      ex = expect_raises(::Sebas::Agents::RegistryError) do
        registry.clone_from_template("no-such-template", "new-one")
      end
      ex.message.as(String).should contain("template agent not found")

      ex2 = expect_raises(::Sebas::Agents::RegistryError) do
        registry.clone_from_template("existing", "existing")
      end
      ex2.message.as(String).should contain("agent already exists")
    end
  end

  describe "Agent 元数据固化（M4x-WP2，#148）" do
    it "AgentInstance 携带 category/tags，registry 首建固化、热更新不刷新存量" do
      dir = Path[Dir.tempdir, "sebas-agent-meta-spec", Random::Secure.hex(4)]
      FileUtils.mkdir_p(dir / "agents")
      registry = ::Sebas::Agents::AgentRegistry.new(dir / "agents")

      # 显式元数据：首建时固化进实例
      writer = registry.get_or_create("writer", category: "writing", tags: ["drafting", "english"])
      writer.category.should eq("writing")
      writer.tags.should eq(["drafting", "english"])

      # 缺省：category nil / tags []
      plain = registry.get_or_create("plain")
      plain.category.should be_nil
      plain.tags.should eq([] of String)

      # 首建固化：同 id 再 get_or_create 传新元数据不刷新已存在实例（幂等命中）
      again = registry.get_or_create("writer", category: "ops", tags: ["oncall"])
      again.should be(writer)
      again.category.should eq("writing")
      again.tags.should eq(["drafting", "english"])

      # 防御性拷贝：调用方后续改动原数组不渗入实例
      external = ["drafting", "english"]
      mutated = registry.get_or_create("frozen", tags: external)
      external << "late-change"
      mutated.tags.should eq(["drafting", "english"])
    end
  end

  describe "SKILL.md frontmatter 角色卡挂点（M4.4-WP2）" do
    it "frontmatter role 字段解析（角色卡挂点）" do
      root = skill_dir("research-sprint", "name: research-sprint\nrole: researcher\ndescription: fast research", "sprint instructions")
      skills, _errors = ::Sebas::Agents::Skills.load_dir(root)
      skills.size.should eq(1)
      skills[0].role.should eq("researcher")
    end

    it "render(role:) 仅注入通用技能与匹配角色卡（无匹配角色卡不注入）" do
      generic = ::Sebas::Agents::Skills::Skill.new("generic", "", "generic body", "/x", nil)
      researcher = ::Sebas::Agents::Skills::Skill.new("sprint", "", "sprint body", "/x", "researcher")
      ops = ::Sebas::Agents::Skills::Skill.new("ops-card", "", "ops body", "/x", "ops")

      rendered = ::Sebas::Agents::Skills.render([generic, researcher, ops], role: "researcher")
      rendered.should contain("generic body")
      rendered.should contain("sprint body")
      rendered.should_not contain("ops body")

      # role=nil 全量注入（现状回归）
      all = ::Sebas::Agents::Skills.render([generic, researcher, ops])
      all.should contain("sprint body")
      all.should contain("ops body")
    end
  end
end
