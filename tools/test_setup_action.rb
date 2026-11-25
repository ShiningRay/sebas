# frozen_string_literal: true

# .github/actions/setup 的契约测试。
#
# ## 为什么需要
#
# 自托管 runner 上 Crystal 工具链的复用逻辑（crystal-cache.sh + action.yml 的
# 四步编排）有几条容易在后续编辑中静默失效的性质：
#
#   1. 只对自托管类 Unix runner 启用——托管 runner 上的收益为零，Windows 的
#      目录布局与 PATH 语义也不同；
#   2. 命中时必须跳过 install-crystal 并自行补注册 problem matcher——否则
#      错误标注在缓存命中后消失，而 CI 仍然是绿的；
#   3. 任何判据不成立都要退回 install-crystal 的默认路径——缓存优化不能把
#      流水线拖红。
#
# 这些都只体现为 YAML 的 if 条件与 shell 分支，改坏了没有别的测试会红。
# 这里同时做结构断言（读 YAML）与行为断言（真跑脚本，用假工具链，全程离线）。
#
# 假工具链按 install-crystal 默认 `shards: true` 的**真实布局**搭：它保留包里
# 自带的 Shards（macOS 在 embedded/bin，Linux 在 bin），不建 "-shards" 目录。
# 早期版本误以为会建独立 shards 目录，那会让命中永远失败。

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "json"
require "yaml"

class SetupActionTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  ACTION = File.join(ROOT, ".github", "actions", "setup", "action.yml")
  SCRIPT = File.join(ROOT, ".github", "actions", "setup", "crystal-cache.sh")
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

  def test_matchers_match_upstream_pinned_shape
    %w[crystal.json crystal-spec.json].each do |file|
      parsed = JSON.parse(File.read(File.join(ROOT, ".github", "actions", "setup", "matchers", file)))
      assert_kind_of Array, parsed["problemMatcher"]
      refute_empty parsed["problemMatcher"]
      parsed["problemMatcher"].each { |m| refute_empty m["pattern"] }
    end
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
    # 用 env -i 隔离宿主的 RUNNER_*，保证断言来自脚本自己的推导逻辑。
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

  # 按 install-crystal 默认 shards=true 的真实布局造一份工具链：
  # 两个平台都在 bin 放 crystal 入口（macOS 是 wrapper，真正的二进制在
  # embedded/bin）；Shards 用包里自带的，macOS 落在 embedded/bin，Linux 在 bin。
  def fake_toolchain(root, version, os: "macOS")
    bin = File.join(root, "bin")
    FileUtils.mkdir_p(bin)
    write_exe(File.join(bin, "crystal"), "Crystal #{version} [abc] (2026-11-13)")
    if os == "macOS"
      embedded = File.join(root, "embedded", "bin")
      FileUtils.mkdir_p(embedded)
      write_exe(File.join(embedded, "crystal"), "Crystal #{version} [abc] (2026-11-13)")
      write_exe(File.join(embedded, "shards"), "Shards 0.20.0")
    else
      write_exe(File.join(bin, "shards"), "Shards 0.20.0")
    end
    root
  end

  def write_exe(path, line)
    File.write(path, "#!/bin/sh\necho '#{line}'\n")
    File.chmod(0o755, path)
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

      fake_toolchain(first["destination"], VERSION)

      _out, status = run_script(["release", first["lock"]], env_for(dir))
      assert status.success?

      _out, status = run_script(["prepare"], env_for(dir))
      assert status.success?

      second = outputs(dir)
      assert_equal "true", second["hit"], "装好后应命中（真实布局不建 -shards 目录）"
      assert_equal first["destination"], second["destination"]
      assert_equal "", second["lock"]

      # GITHUB_PATH prepend：后写的行更靠前，所以 bin 必须是最后一行。
      lines = path_lines(dir)
      assert_equal File.join(first["destination"], "bin"), lines.last
      assert_includes lines, File.join(first["destination"], "embedded", "bin")
    end
  end

  def test_linux_layout_uses_only_bin
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(env_for(dir)["RUNNER_TEMP"])
      env = env_for(dir, "RUNNER_OS" => "Linux")

      _out, = run_script(["prepare"], env)
      first = outputs(dir)
      fake_toolchain(first["destination"], VERSION, os: "Linux")
      run_script(["release", first["lock"]], env)

      _out, status = run_script(["prepare"], env)
      assert status.success?
      assert_equal "true", outputs(dir)["hit"]
      assert_equal [File.join(first["destination"], "bin")], path_lines(dir)
    end
  end

  def test_missing_shards_is_not_reused
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(env_for(dir)["RUNNER_TEMP"])
      _out, = run_script(["prepare"], env_for(dir))
      first = outputs(dir)
      run_script(["release", first["lock"]], env_for(dir))

      # 只有 crystal、没有 shards：半截安装，判定不可复用。
      bin = File.join(first["destination"], "bin")
      FileUtils.mkdir_p(bin)
      write_exe(File.join(bin, "crystal"), "Crystal #{VERSION} [abc]")
      FileUtils.mkdir_p(File.join(first["destination"], "embedded", "bin"))
      write_exe(File.join(first["destination"], "embedded", "bin", "crystal"),
        "Crystal #{VERSION} [abc]")

      _out, status = run_script(["prepare"], env_for(dir))
      assert status.success?
      assert_equal "false", outputs(dir)["hit"], "缺 shards 必须重装"
      assert_equal File.join(File.dirname(first["destination"]), "#{VERSION}.lock"),
        outputs(dir)["lock"], "重装时应重新持锁"
    end
  end

  def test_version_mismatch_in_cached_binary_is_not_reused
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(env_for(dir)["RUNNER_TEMP"])
      _out, = run_script(["prepare"], env_for(dir))
      first = outputs(dir)
      run_script(["release", first["lock"]], env_for(dir))

      # 目录名对、二进制自报版本不对（比如目录被别的版本覆盖过）。
      fake_toolchain(first["destination"], "9.9.0")
      _out, = run_script(["prepare"], env_for(dir))
      assert_equal "false", outputs(dir)["hit"]
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
      assert_equal "", second["lock"], "抢不到锁就不该声称持锁"
      assert_includes second["destination"].to_s, "crystal-staging-",
        "抢不到锁时应装到私有暂存目录，避免交叉写入"
      assert_includes second["destination"].to_s, env_for(dir)["RUNNER_TEMP"]

      run_script(["release", first["lock"]], env_for(dir))
    end
  end

  def test_lock_holder_rechecks_cache_before_clearing
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(env_for(dir)["RUNNER_TEMP"])
      # 未命中时拿到锁，但还没装；此后另一台 job 抢先装好并放了锁。
      _out, = run_script(["prepare"], env_for(dir))
      first = outputs(dir)
      run_script(["release", first["lock"]], env_for(dir))
      fake_toolchain(first["destination"], VERSION)

      _out, status = run_script(["prepare"], env_for(dir))
      assert status.success?
      result = outputs(dir)
      assert_equal "true", result["hit"], "拿着锁也要先重判缓存，别人刚装好就直接复用"
      assert_equal "", result["lock"], "复用路径不能留着锁"
      refute_empty path_lines(dir)
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

  def test_fresh_lock_is_respected
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(env_for(dir)["RUNNER_TEMP"])
      lock = File.join(env_for(dir)["RUNNER_TOOL_CACHE"], "crystal-toolchain", "#{VERSION}.lock")
      FileUtils.mkdir_p(lock)

      _out, status = run_script(["prepare"], env_for(dir))
      assert status.success?
      assert_equal "", outputs(dir)["lock"], "新鲜锁不能被抢"
      assert_includes outputs(dir)["destination"].to_s, "crystal-staging-"
    end
  end
end
