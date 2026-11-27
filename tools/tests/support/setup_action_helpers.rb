# .github/actions/setup 的结构与行为夹具。
#
# 测试文件按「结构断言 / 行为断言」拆成两半后，夹具要共用：这套假工具链
# 必须按官方包的真实布局搭建，改一处就要两半都跑得过。
require "open3"
require "yaml"

module SetupActionHelpers
  ROOT = RepoPaths::ROOT
  ACTION = RepoPaths.join(".github", "actions", "setup", "action.yml")
  SCRIPT = RepoPaths.join(".github", "actions", "setup", "crystal-cache.sh")
  VERSION = "9.9.9"

  def action
    @action ||= YAML.safe_load(File.read(ACTION, encoding: "UTF-8"))
  end

  def steps
    @steps ||= action.dig("runs", "steps")
  end

  def step(name)
    found = steps.find { |s| s["name"] == name }
    refute_nil found, "缺少步骤：#{name}"
    found
  end

  # 用 env -i 隔离宿主的 RUNNER_*，保证断言来自脚本自己的推导逻辑。
  def env_for(dir, overrides = {})
    {
      "RUNNER_TEMP" => File.join(dir, "_work", "_temp"),
      "RUNNER_OS" => "macOS",
      "CRYSTAL_REQUESTED" => VERSION,
      "GITHUB_OUTPUT" => File.join(dir, "output"),
      "GITHUB_PATH" => File.join(dir, "path"),
      "RUNNER_TOOL_CACHE" => File.join(dir, "_work", "_tool")
    }.merge(overrides)
  end

  def run_script(args, env)
    pairs = env.compact.map { |k, v| "#{k}=#{v}" }
    Open3.capture2e({}, "/usr/bin/env", "-i", "PATH=/usr/bin:/bin", *pairs,
      "bash", SCRIPT, *args)
  end

  # 每次 prepare 前清空输出：否则上一次的 hit=... 会掩盖本次提前退出。
  def prepare(env, dir)
    FileUtils.rm_f(File.join(dir, "output"))
    out, status = run_script(["prepare"], env)
    assert status.success?, "prepare 不应失败：#{out}"
    outputs(dir)
  end

  # 收尾：写完成标记 + 放锁。参数顺序与 action.yml 一致。
  # installed 对应 CRYSTAL_CACHE_INSTALLED，默认 true 表示安装步骤成功。
  def release(result, env, installed: "true")
    run_script(["release", result["lock"].to_s, result["owner"].to_s,
                result["destination"].to_s, result["version"].to_s, installed], env)
  end

  def outputs(dir)
    path = File.join(dir, "output")
    return {} unless File.exist?(path)

    File.readlines(path, chomp: true).to_h { |line| line.split("=", 2) }.compact
  end

  def path_lines(dir)
    path = File.join(dir, "path")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  # 按官方包的真实布局造一份工具链。marker 非空时 macOS 的 wrapper 会把自己
  # 的执行记进去——用来证明校验真的跑到了 wrapper，而不只是 stat 到文件。
  def fake_toolchain(root, version, os: "macOS", marker: nil)
    bin = File.join(root, "bin")
    FileUtils.mkdir_p(bin)
    if os == "macOS"
      embedded = File.join(root, "embedded", "bin")
      FileUtils.mkdir_p(embedded)
      write_exe(File.join(embedded, "crystal"), "Crystal #{version} [abc] (2026-11-13)")
      write_exe(File.join(embedded, "shards"), "Shards 0.20.0")
      # 官方 wrapper：#!/usr/bin/env bash，靠 dirname / realpath 定位自身。
      wrapper = +"#!/usr/bin/env bash\n"
      wrapper << %(echo ran >> "#{marker}"\n) if marker
      wrapper << %(SCRIPT_PATH="$(dirname "$(realpath "$0" || echo $0)")"\n)
      wrapper << %(INSTALL_DIR="$(realpath "$SCRIPT_PATH/..")"\n)
      wrapper << %("$INSTALL_DIR/embedded/bin/crystal" "$@"\n)
      File.write(File.join(bin, "crystal"), wrapper)
      File.chmod(0o755, File.join(bin, "crystal"))
      FileUtils.mkdir_p(File.join(root, "src"))
      File.write(File.join(root, "src", "prelude.cr"), "# macOS 包的标准库\n")
    else
      write_exe(File.join(bin, "crystal"), "Crystal #{version} [abc] (2026-11-13)")
      write_exe(File.join(bin, "shards"), "Shards 0.20.0")
      FileUtils.mkdir_p(File.join(root, "share", "crystal", "src"))
      File.write(File.join(root, "share", "crystal", "src", "prelude.cr"), "# Linux 包的标准库\n")
    end
    root
  end

  def write_exe(path, line)
    File.write(path, "#!/bin/sh\necho '#{line}'\n")
    File.chmod(0o755, path)
  end

  def cache_root(env)
    File.join(env["RUNNER_TOOL_CACHE"], "crystal-toolchain")
  end
end
