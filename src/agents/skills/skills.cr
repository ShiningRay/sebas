require "log"
require "yaml"
require "../../log"

# SKILL.md 加载器（M0-WP6b，A7 升格为主要扩展通道）：
# skills 目录发现 → SKILL.md 解析（frontmatter: name/description + 正文指令）→
# 注入 agent system prompt。坏 SKILL.md 不崩进程——错误转值（B6 缓解）。
# M0-M2 的扩展需求由 SKILL.md 承接（design.md §14 排期依据）。
module Sebas
  module Agents
    module Skills
      Log = Sebas::Log.for("agents.skills")

      # role（M4.4-WP2 角色卡挂点）：frontmatter `role:` 声明该技能适用的
      # fork 角色名——fork role 参数与之匹配时该技能优先注入（角色卡）。
      record Skill, name : String, description : String, instructions : String, path : String, role : String? = nil
      record LoadedSkill, skill : Skill?
      record SkillError, path : String, message : String

      # 目录发现 + 解析：返回 (合法技能, 错误列表)——错误转值，不炸进程
      def self.load_dir(skills_dir : String | Path) : Tuple(Array(Skill), Array(SkillError))
        skills = [] of Skill
        errors = [] of SkillError
        dir = Path[skills_dir]
        return {skills, errors} unless Dir.exists?(dir)
        Dir.children(dir).sort.each do |entry|
          path = dir / entry
          next unless File.directory?(path)
          skill_file = path / "SKILL.md"
          next unless File.exists?(skill_file)
          parse(skill_file).try do |parsed|
            if parsed.is_a?(Skill)
              skills << parsed
            elsif parsed.is_a?(SkillError)
              errors << parsed
            end
          end
        end
        {skills, errors}
      rescue ex : ::Exception
        {[] of Skill, [SkillError.new(Path[skills_dir].to_s, "skills dir unreadable: #{ex.message}")]}
      end

      # 单文件解析：YAML frontmatter（--- 包围）+ 正文。role 为角色卡挂点
      def self.parse(path : Path) : Skill | SkillError
        raw = File.read(path)
        name, description, instructions, role = split_frontmatter(raw)
        if name.nil? || name.strip.empty?
          return SkillError.new(path.to_s, "frontmatter missing or name empty")
        end
        Skill.new(name.strip, description || "", instructions.strip, path.to_s, role)
      rescue ex : ::Exception
        SkillError.new(path.to_s, "unreadable: #{ex.message}")
      end

      private def self.split_frontmatter(raw : String) : Tuple(String?, String?, String, String?)
        return {nil, nil, raw, nil} unless raw.starts_with?("---")
        closed = raw.index("---", 3)
        return {nil, nil, raw, nil} unless closed
        fm = raw[3...closed]
        body = raw[closed + 3..].lstrip("\r\n-")
        begin
          meta = YAML.parse(fm)
          name = meta["name"]?.try(&.as_s?)
          description = meta["description"]?.try(&.as_s?)
          role = meta["role"]?.try(&.as_s?)
          {name, description, body, role}
        rescue YAML::ParseException
          {nil, nil, raw, nil}
        end
      end

      # 注入 agent system prompt 的技能面（与工具面 describe 同款格式）。
      # role 指定（M4.4-WP2 角色卡）：仅注入通用技能（无 role）与匹配该
      # 角色的技能卡；role=nil 时全量注入（现状）。
      def self.render(skills : Array(Skill), role : String? = nil) : String
        return "" if skills.empty?
        selected = role ? skills.select { |entry| entry.role.nil? || entry.role == role } : skills
        return "" if selected.empty?
        String.build do |output|
          output << "## Skills\n"
          selected.each do |skill|
            output << "### #{skill.name}"
            output << ": #{skill.description}" unless skill.description.empty?
            output << "\n"
            output << skill.instructions
            output << "\n\n"
          end
        end.rstrip("\n")
      end
    end
  end
end
