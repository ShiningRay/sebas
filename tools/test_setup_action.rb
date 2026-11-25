# frozen_string_literal: true

# .github/actions/setup 的契约测试。
#
# ## 为什么需要
#
# 自托管 runner 上 Crystal 工具链的复用逻辑（crystal-cache.sh + action.yml 的三步
# 编排）有三条容易在后续编辑中静默失效的性质：
#
#   1. 只对自托管类 Unix runner 启用——托管 runner 的 _tool 目录不保证可写，
#      Windows 的目录布局与 PATH 语义也不同；
#   2. 命中时必须跳过 install-crystal 并自行补注册 problem matcher——否则
#      错误标注在缓存命中后消失，而 CI 仍然是绿的；
#   3. 任何判据不成立都要退回 install-crystal 的默认路径——缓存优化不能把
#      流水线拖红。
#
# 这些都只体现为 YAML 的 if 条件与 shell 分支，改坏了没有任何其他测试会红。
# 这里同时做结构断言（读 YAML）与行为断言（真跑脚本，用假工具链，全程离线）。

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"

class SetupActionTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  ACTION = File.join(ROOT, ".github", "actions", "setup", "action.yml")
  SCRIPT = File.join(ROOT, ".github", "actions", "setup", "crystal-cache.sh")
  VERSION = "9.9.9"

  def action
    @action ||= YAML.safe_load_file(ACTION)
  end

  def steps
    @steps ||= action.dig("runs", "steps")
  end

  def step(name)
    found = steps.find { |s| s["name"] == name }
    refute_nil found, "缺少步骤：#{name}"
    found
  end

  # --- 结构 ---

  def test_prepare_step_is_self_hosted_unix_only
    condition = step("Prepare Crystal toolchain cache")["if"].to_s
    assert_includes condition, "runner.environment == 'self-hosted'"
    assert_includes condition, "runner.os != 'Windows'"
  end

  def test_install_step_is_skipped_on_hit_and_uses_cache_destination
    install = step("Install Crystal")
    assert_includes install["if"].to_s, "steps.crystal_cache.outputs.hit != 'true'"
    assert_equal "${{ steps.crystal_cache.outputs.destination }}", install.dig("with", "destination")
  end

  def test_matchers_are_registered_on_hit
    # install-crystal 只在它自己跑的时候注册 matcher；命中路径要补齐，
    # 否则缓存生效后编译错误不再有 annotation。
    matcher = step("Register Crystal problem matchers")
    assert_includes matcher["if"].to_s, "steps.crystal_cache.outputs.hit == 'true'"
    %w[crystal.json crystal-spec.json].each do |file|
      assert File.file?(File.join(ROOT, ".github", "actions", "setup", "matchers", file)),
        "缺少 matcher 文件：#{file}"
    end
  end

  def test_lock_release_always_runs
    release = step("Release Crystal toolchain cache lock")
    assert_includes release["if"].to_s, "always()"
    assert_includes release["if"].to_s, "steps.crystal_cache.outputs.lock != ''"
  end

  def test_script_is_executable_and_syntax_clean
    assert File.executable?(SCRIPT), "crystal-cache.sh 应可执行"
    out, status = Open3.capture2e("bash", "-n", SCRIPT)
    assert status.success?, out
  end

  # --- 行为 ---

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
    # 用 env -i 隔离宿主的 RUNNER_*，保证断言来自脚本自身的推导逻辑。
    pairs = env.compact.map { |k, v| "#{k}=#{v}" }
    Open3.capture2e({}, "/usr/bin/env", "-i", "PATH=/usr/bin:/bin", *pairs,
      "bash", SCRIPT, *args)
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

  def fake_toolchain(root, version)
    FileUtils.mkdir_p(File.join(root, "bin"))
    FileUtils.mkdir_p(File.join(root, "embedded", "bin"))
    %w[bin/crystal embedded/bin/crystal].each do |rel|
      file = File.join(root, rel)
      File.write(file, "#!/bin/sh\necho 'Crystal #{version} [abc] (2026-11-13)'\n")
      File.chmod(0o755, file)
    end
    FileUtils.mkdir_p(File.join("#{root}-shards", "bin"))
    shards = File.join("#{root}-shards", "bin", "shards")
    File.write(shards, "#!/bin/sh\necho 'Shards 0.20.0'\n")
    File.chmod(0o755, shards)
  end

  def test_miss_then_hit_round_trip
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(env_for(dir)["RUNNER_TEMP"])

      _out, status = run_script(["prepare"], env_for(dir))
      assert status.success?

      first = outputs(dir)
      assert_equal "false", first["hit"]
      refute_empty first["destination"], "未命中时应把安装目录指进缓存"
      refute_empty first["lock"], "未命中时应持锁，供收尾释放"
      assert File.directory?(first["lock"]), "锁应是 mkdir 出来的目录"

      # 模拟 install-crystal 装到 destination 与 "-shards"。
      fake_toolchain(first["destination"], VERSION)

      _out, status = run_script(["release", first["lock"]], env_for(dir))
      assert status.success?

      _out, status = run_script(["prepare"], env_for(dir))
      assert status.success?

      second = outputs(dir)
      assert_equal "true", second["hit"], "装好后应命中"
      assert_equal first["destination"], second["destination"]
      assert_empty path_lines(dir).select { |l| l.end_with?(".lock") }

      # PATH 里 shards 目录最靠前（GITHUB_PATH prepend 语义）。
      lines = path_lines(dir)
      assert_equal File.join("#{first["destination"]}-shards", "bin"), lines.last
      assert_includes lines, File.join(first["destination"], "embedded", "bin")
      assert_includes lines, File.join(first["destination"], "bin")
    end
  end

  def test_incomplete_cache_is_not_reused
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(env_for(dir)["RUNNER_TEMP"])
      _out, = run_script(["prepare"], env_for(dir))
      first = outputs(dir)
      _out, = run_script(["release", first["lock"]], env_for(dir))

      # 只有 crystal 没有 shards：判定不可复用。
      FileUtils.mkdir_p(File.join(first["destination"], "bin"))
      crystal = File.join(first["destination"], "bin", "crystal")
      File.write(crystal, "#!/bin/sh\necho 'Crystal #{VERSION} [abc]'\n")
      File.chmod(0o755, crystal)

      _out, status = run_script(["prepare"], env_for(dir))
      assert status.success?
      assert_equal "false", outputs(dir)["hit"], "半截缓存必须重装"
      assert_equal File.join(File.dirname(first["destination"]), "#{VERSION}.lock"),
        outputs(dir)["lock"], "重装时应重新持锁"
      run_script(["release", outputs(dir)["lock"]], env_for(dir))
    end
  end

  def test_unpinnable_version_falls_back_to_default_path
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(env_for(dir)["RUNNER_TEMP"])
      ["nightly", "1.22"].each do |requested|
        _out, status = run_script(["prepare"], env_for(dir, "CRYSTAL_REQUESTED" => requested))
        assert status.success?, "#{requested} 不应让脚本失败"
        result = outputs(dir)
        assert_equal "false", result["hit"]
        assert_equal "", result["destination"], "#{requested} 应回落到 install-crystal 默认目录"
        assert_equal "", result["lock"]
      end
    end
  end

  def test_missing_tool_cache_and_runner_temp_falls_back
    Dir.mktmpdir do |dir|
      env = env_for(dir).merge("RUNNER_TOOL_CACHE" => nil, "RUNNER_TEMP" => nil)
      _out, status = run_script(["prepare"], env)
      assert status.success?
      result = outputs(dir)
      assert_equal "false", result["hit"]
      assert_equal "", result["destination"]
      assert_equal "", result["lock"]
    end
  end

  def test_tool_cache_is_derived_from_runner_temp
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(env_for(dir)["RUNNER_TEMP"])
      env = env_for(dir).merge("RUNNER_TOOL_CACHE" => nil)
      _out, status = run_script(["prepare"], env)
      assert status.success?
      expected = File.join(dir, "_work", "_tool", "crystal-toolchain", VERSION)
      assert_equal expected, outputs(dir)["destination"],
        "自托管 runner 未导出 RUNNER_TOOL_CACHE 时应由 RUNNER_TEMP 推出 _work/_tool"
    end
  end

  def test_held_lock_makes_the_second_job_use_a_private_staging_dir
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(env_for(dir)["RUNNER_TEMP"])
      _out, = run_script(["prepare"], env_for(dir))
      first = outputs(dir)
      # 不 release，模拟另一个 job 正在装。

      _out, status = run_script(["prepare"], env_for(dir))
      assert status.success?
      second = outputs(dir)
      assert_equal "false", second["hit"]
      assert_empty second["lock"].to_s, "抢不到锁就不该声称持锁"
      assert_includes second["destination"].to_s, "crystal-staging-",
        "抢不到锁时应装到私有暂存目录，避免交叉写入"
      assert_includes second["destination"].to_s, env_for(dir)["RUNNER_TEMP"]

      # 收尾释放，避免影响后续断言。
      run_script(["release", first["lock"]], env_for(dir))
    end
  end

  def test_stale_lock_is_taken_over
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(env_for(dir)["RUNNER_TEMP"])
      lock = File.join(env_for(dir)["RUNNER_TOOL_CACHE"], "crystal-toolchain", "#{VERSION}.lock")
      FileUtils.mkdir_p(lock)
      old = Time.now - 3600
      File.utime(old, old, lock)

      _out, status = run_script(["prepare"], env_for(dir))
      assert status.success?
      assert_equal lock, outputs(dir)["lock"], "超过 TTL 的锁应被接管"
    end
  end
end
