# frozen_string_literal: true

require "date"
require "rubygems"

module SebasAgents
  # Release Manager 的确定性部分：决定是否发版、下一版本号、校验顺序。
  # 真正写文件、打 tag、推远端由调用方在 --apply 时执行。
  module Release
    module_function

    COMMIT_RE = /\A(?<type>[a-z]+)(?:\([^)]*\))?!?:\s/

    # 返回 Hash：
    #   action: "patch" | "skip" | "noop"
    #   reason: String
    #   current / next_version: String
    def plan(latest_tag:, subjects:, today: Date.today)
      current = normalise_version(latest_tag)
      types = subjects.filter_map { |subject| subject[COMMIT_RE, "type"] }

      if types.include?("feat")
        return {
          "action" => "skip",
          "reason" => "检测到 feat，跳过 patch 发版；fix 如需紧急发布请走 hotfix",
          "current" => current,
          "next_version" => nil
        }
      end
      unless types.include?("fix")
        return {"action" => "noop", "reason" => "无 fix 提交", "current" => current, "next_version" => nil}
      end

      next_version = bump_patch(current)
      {
        "action" => "patch",
        "reason" => "存在 fix 提交且无 feat，发 patch",
        "current" => current,
        "next_version" => next_version,
        "today" => today.iso8601
      }
    end

    def normalise_version(tag)
      version = tag.to_s.delete_prefix("v")
      unless version.match?(/\A\d+\.\d+\.\d+\z/)
        raise UsageError, "tag #{tag.inspect} 不是 vX.Y.Z"
      end
      version
    end

    def bump_patch(version)
      parts = normalise_version(version).split(".").map { |part| Integer(part, 10) }
      (parts[0..-2] + [parts.last + 1]).join(".")
    end

    def strictly_increasing?(current, next_version)
      Gem::Version.new(next_version) > Gem::Version.new(current)
    end

    # 产物校验：只核对 sha256 清单与冒烟输出，不自行下载。
    # 冒烟输出自 v0.1.0 起为 `sebas X.Y.Z (<git rev>)`；不带 rev 的旧形态也接受。
    def verify_assets(dir, version, expected: nil)
      problems = []
      sidecars = Dir.glob(File.join(dir, "*.sha256")).sort
      problems << "无 *.sha256 产物" if sidecars.empty?

      sidecars.each do |sidecar|
        status = system("sha256sum", "-c", File.basename(sidecar), chdir: dir,
          out: File::NULL, err: File::NULL)
        problems << "sha256 校验失败：#{File.basename(sidecar)}" unless status
      end

      if expected && !smoke_output_matches?(version, expected)
        problems << "冒烟输出不符：期望 sebas #{version}[(<git rev>)]，实际 #{expected.strip.inspect}"
      end

      problems
    end

    # `sebas version` 的合法输出：`sebas X.Y.Z`，或带构建 git rev 的
    # `sebas X.Y.Z (<rev>)`。rev 允许 unknown（无 .git 的源码包构建）。
    def smoke_output_matches?(version, output)
      output.strip.match?(/\Asebas #{Regexp.escape(version)}(?: \(\S+\))?\z/)
    end
  end
end
