require "spec"
require "file_utils"
require "../../src/agents/skills/skills"

def skills_tmp_dir : Path
  dir = Path[ENV["TEMP"], "sebas-skills-spec", Random::Secure.hex(4)]
  FileUtils.rm_rf(dir)
  Dir.mkdir_p(dir)
  dir
end

def write_skill(dir : Path, name : String, content : String) : Path
  Dir.mkdir_p(dir / name)
  path = dir / name / "SKILL.md"
  File.write(path, content)
  path
end

module Sebas
  describe "SKILL.md loader (M0-WP6b, A7)" do
    it "discovers skills, parses frontmatter, and renders for prompt injection" do
      dir = skills_tmp_dir
      write_skill(dir, "email-triage", "---\nname: email-triage\ndescription: Triage incoming mail\n---\n1. Summarize the mail\n2. Draft a reply")
      skills, errors = Agents::Skills.load_dir(dir)
      errors.should be_empty
      skills.size.should eq(1)
      skill = skills.first
      skill.name.should eq("email-triage")
      skill.description.should eq("Triage incoming mail")
      skill.instructions.should contain("Summarize the mail")

      rendered = Agents::Skills.render(skills)
      rendered.should contain("## Skills")
      rendered.should contain("### email-triage: Triage incoming mail")
      FileUtils.rm_rf(dir)
    end

    it "degrades broken SKILL.md files to values without crashing (B6 缓解)" do
      dir = skills_tmp_dir
      write_skill(dir, "no-frontmatter", "just some text without frontmatter")
      write_skill(dir, "empty-name", "---\nname: \"\"\ndescription: d\n---\nbody")
      skills, errors = Agents::Skills.load_dir(dir)
      skills.should be_empty
      errors.size.should eq(2)
      errors.first.message.should_not be_empty
      Agents::Skills.render(skills).should eq("")
      FileUtils.rm_rf(dir)
    end

    it "returns empty on a missing skills dir" do
      skills, errors = Agents::Skills.load_dir(Path[ENV["TEMP"], "sebas-skills-spec", "nonexistent-xyz"])
      skills.should be_empty
      errors.should be_empty
    end
  end
end
