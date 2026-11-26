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
# 假工具链照官方包的真实布局搭（对照 crystal 1.22.3 的 darwin / linux 资产）：
#   macOS: bin/crystal 是 `#!/usr/bin/env bash` 的 wrapper，真二进制在
#          embedded/bin/crystal，Shards 在 embedded/bin，标准库在 src/。
#   Linux: bin/crystal 与 bin/shards 都是二进制，标准库在 share/crystal/src/。
# 两平台的 Shards 都来自包里自带的那份——默认 shards=true 不会建 "-shards"。

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

  def test_lock_release_always_runs_and_passes_the_owner
    release = step("Release Crystal toolchain cache lock")
    assert_includes release["if"].to_s, "always()"
    assert_includes release["if"].to_s, "steps.crystal_cache.outputs.lock != ''"
    # owner 是「只放自己的锁」的唯一依据，必须传；完成标记还要 destination
    # 与 version，缺了就永远打不上标记、缓存永远命中不了。
    env = release["env"]
    assert_equal "${{ steps.crystal_cache.outputs.owner }}", env["CRYSTAL_CACHE_OWNER"]
    assert_equal "${{ steps.crystal_cache.outputs.destination }}", env["CRYSTAL_CACHE_ROOT"]
    assert_equal "${{ steps.crystal_cache.outputs.version }}", env["CRYSTAL_CACHE_VERSION"]
  end

  # 安装失败的目录不能盖章：install-crystal 的 Linux 分支并行装依赖，依赖失败时
  # 包可能已经解开，只看内容物会把「机器缺 libssl-dev」固化进缓存。
  def test_install_outcome_is_passed_to_the_release_step
    update = step("Release Crystal toolchain cache lock").dig("env", "CRYSTAL_CACHE_INSTALLED")
    assert_equal "${{ steps.install_crystal.outcome == 'success' }}", update,
      "必须以 Install Crystal 的 outcome 为依据，且该步骤要有 id"
    assert_equal "install_crystal", step("Install Crystal")["id"]
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

  # vcpkg 的二进制缓存目录写三处：restore 与 save 的 path，以及安装步骤里的
  # VCPKG_DEFAULT_BINARY_CACHE。任一处改了而其余没跟上，缓存会命中但用不上
  # ——CI 仍然是绿的，只是白跑一趟缓存，无声无息。
  def test_vcpkg_cache_path_matches_the_install_step
    restore = step("Restore vcpkg binary cache")
    save = step("Save vcpkg binary cache")
    cache_dir = ".vcpkg-archives"

    # action 类型分开断言：合成一个 (restore|save) 正则时，把恢复步骤误写成
    # save 也能通过——而那样缓存就永远只会写不会读（CodeRabbit Minor）。
    {restore => "restore", save => "save"}.each do |entry, kind|
      assert_equal cache_dir, entry.dig("with", "path"),
        "#{entry["name"]} 的 path 必须与实际落盘目录一致"
      assert_includes entry["if"].to_s, "runner.os == 'Windows'"
      assert_match(%r{\Aactions/cache/#{kind}@[0-9a-f]{40}\z}, entry["uses"].to_s,
        "#{entry["name"]} 必须使用 actions/cache/#{kind} 且 SHA 钉版")
    end
    # restore 与 save 必须指向同一目录，否则存进去的读不回来。
    assert_equal restore.dig("with", "path"), save.dig("with", "path")

    install = step("Install SQLite3 (Windows)")["run"]
    assert_includes install, %($env:VCPKG_DEFAULT_BINARY_CACHE = "$PWD\\#{cache_dir}"),
      "安装步骤必须把 vcpkg 的二进制缓存指到同一个目录"
  end

  # 目录创建必须在 vcpkg install 之前：vcpkg 在缓存目录不存在时直接失败，
  # 顺序颠倒会让两个平台之间只差一行，问题只在 Windows CI 上暴露。
  def test_vcpkg_cache_dir_is_created_before_install
    install = step("Install SQLite3 (Windows)")["run"]
    made = install.index("New-Item -ItemType Directory -Force -Path $env:VCPKG_DEFAULT_BINARY_CACHE")
    used = install.index('vcpkg install "sqlite3[fts5]:x64-windows"')

    refute_nil made, "安装步骤必须先创建缓存目录"
    refute_nil used
    assert made < used, "目录创建必须出现在 vcpkg install 之前"
  end

  # 主键必须带 run_id，且 restore/save 两步一致。
  #
  # 固定主键会让 actions/cache 在「主键已存在」时拒绝再写：镜像升级导致 sqlite3
  # 重建后，新包永远存不进去，优化静默退化为每轮 39s。这条测试锁住这个坑。
  # 主键里也不得掺 github.job：同一 run 里 spec 与 release-build 共享一份包更省，
  # 而 save 的主键冲突只记 warning，不会把 job 变红。
  def test_vcpkg_cache_key_is_per_run_and_shared_by_restore_and_save
    restore = step("Restore vcpkg binary cache")
    save = step("Save vcpkg binary cache")
    key = "vcpkg-archives-${{ runner.os }}-${{ github.run_id }}"

    assert_equal key, restore.dig("with", "key").to_s
    assert_equal key, save.dig("with", "key").to_s, "restore 与 save 的主键必须一致"
    refute_includes key, "github.job", "同 run 内的 job 应共享同一份二进制包"
    assert_equal "vcpkg-archives-${{ runner.os }}-", restore.dig("with", "restore-keys").to_s,
      "前缀兜底要能取到上一轮的缓存"
    assert_includes save["if"].to_s, "steps.vcpkg_cache.outputs.cache-hit != 'true'",
      "精确命中时不必重复写"
    assert_match(%r{\Aactions/cache/save@[0-9a-f]{40}\z}, save["uses"].to_s)
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

  def test_miss_then_hit_round_trip
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])

      first = prepare(env, dir)
      assert_equal "false", first["hit"]
      assert_equal VERSION, first["version"]
      refute_empty first["destination"], "未命中时应把安装目录指进缓存"
      refute_empty first["lock"], "未命中时应持锁，供收尾释放"
      assert File.directory?(first["lock"]), "锁应是 mkdir 出来的目录"
      refute_empty first["owner"], "持锁时必须留下所有权凭据"

      fake_toolchain(first["destination"], VERSION)
      release(first, env)

      refute File.exist?(first["lock"]), "收尾应放锁"
      assert_equal VERSION,
        File.read(File.join(first["destination"], ".sebas-complete")).strip,
        "收尾应写完成标记"

      second = prepare(env, dir)
      assert_equal "true", second["hit"], "装好后应命中（真实布局不建 -shards 目录）"
      assert_equal first["destination"], second["destination"]
      assert_equal "", second["lock"]

      # GITHUB_PATH prepend：后写的行更靠前，所以 bin 必须是最后一行。
      lines = path_lines(dir)
      assert_equal File.join(first["destination"], "bin"), lines.last
      assert_includes lines, File.join(first["destination"], "embedded", "bin")
    end
  end

  # wrapper 需要 bash / dirname / realpath 才能起来。只给缓存那两个目录会让它
  # 以 127 退出，完好的缓存被判成未命中——本 PR 在 macOS 上的收益归零。
  #
  # 注意先把 marker 删掉再跑第二次 prepare：release 里的 installed_ok 同样会
  # 执行 wrapper 并留下记录，不清掉的话断言会被上一次的痕迹满足，即使第二次
  # 的命中校验根本没跑 wrapper 也照样绿。
  def test_macos_wrapper_can_really_run_from_the_cache_path
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      first = prepare(env, dir)
      marker = File.join(dir, "wrapper-ran")
      fake_toolchain(first["destination"], VERSION, os: "macOS", marker: marker)
      release(first, env)

      FileUtils.rm_f(marker)
      second = prepare(env, dir)
      assert_equal "true", second["hit"]
      assert File.file?(marker), "校验必须真的执行 wrapper，而不是只检查文件存在"
      assert_includes File.read(marker), "ran"
    end
  end

  def test_linux_layout_uses_only_bin
    Dir.mktmpdir do |dir|
      env = env_for(dir, "RUNNER_OS" => "Linux")
      FileUtils.mkdir_p(env["RUNNER_TEMP"])

      first = prepare(env, dir)
      fake_toolchain(first["destination"], VERSION, os: "Linux")
      release(first, env)

      second = prepare(env, dir)
      assert_equal "true", second["hit"]
      assert_equal [File.join(first["destination"], "bin")], path_lines(dir)
    end
  end

  # 只有 crystal、没有 shards：半截安装，判定不可复用。
  def test_missing_shards_is_not_reused
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      first = prepare(env, dir)
      fake_toolchain(first["destination"], VERSION)
      FileUtils.rm_f(File.join(first["destination"], "embedded", "bin", "shards"))
      release(first, env)

      second = prepare(env, dir)
      assert_equal "false", second["hit"], "缺 shards 必须重装"
      assert_equal first["lock"], second["lock"], "重装时应重新持锁"
    end
  end

  # onlySubdir 逐个 mv 子目录：中途被中断时 bin 可能已就位、标准库还没到。
  # 那时的工具链 `crystal --version` 照样通过（不需要标准库），但编译一定
  # 失败，而且会一直失败到有人手动删缓存。
  def test_missing_stdlib_is_not_reused
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      first = prepare(env, dir)
      fake_toolchain(first["destination"], VERSION)
      release(first, env)
      FileUtils.rm_rf(File.join(first["destination"], "src"))

      second = prepare(env, dir)
      assert_equal "false", second["hit"], "标准库没就位就不能算可用"
    end
  end

  # 没有完成标记 = 上个 job 装到一半被中断，一律当半成品。
  def test_missing_completion_marker_is_not_reused
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      first = prepare(env, dir)
      fake_toolchain(first["destination"], VERSION)
      # 故意不叫 release：模拟 release 步骤没跑（job 被强杀）。
      FileUtils.rm_rf(first["lock"])

      second = prepare(env, dir)
      assert_equal "false", second["hit"], "没有完成标记就不能算装好"
    end
  end

  def test_version_mismatch_in_cached_binary_is_not_reused
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      first = prepare(env, dir)
      fake_toolchain(first["destination"], VERSION)
      release(first, env)

      # 标记对、二进制自报版本不对（比如目录被别的版本覆盖过）。
      fake_toolchain(first["destination"], "9.9.0")
      second = prepare(env, dir)
      assert_equal "false", second["hit"]
    end
  end

  def test_unpinnable_version_falls_back_to_default_path
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      # 两者都钉不住具体版本：nightly 天天变，1.22 是前缀式。
      ["nightly", "1.22"].each do |requested|
        result = prepare(env.merge("CRYSTAL_REQUESTED" => requested), dir)
        assert_equal "false", result["hit"]
        assert_equal "", result["destination"], "#{requested} 应回落到 install-crystal 默认目录"
        assert_equal "", result["lock"]
      end
    end
  end

  def test_missing_tool_cache_and_runner_temp_falls_back
    Dir.mktmpdir do |dir|
      env = env_for(dir).merge("RUNNER_TOOL_CACHE" => nil, "RUNNER_TEMP" => nil)
      result = prepare(env, dir)
      assert_equal "false", result["hit"]
      assert_equal "", result["destination"]
      assert_equal "", result["lock"]
    end
  end

  def test_tool_cache_is_derived_from_runner_temp
    Dir.mktmpdir do |dir|
      env = env_for(dir).merge("RUNNER_TOOL_CACHE" => nil)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      result = prepare(env, dir)
      expected = File.join(dir, "_work", "_tool", "crystal-toolchain", VERSION)
      assert_equal expected, result["destination"],
        "自托管 runner 未导出 RUNNER_TOOL_CACHE 时应由 RUNNER_TEMP 推出 _work/_tool"
    end
  end

  def test_held_lock_makes_the_second_job_use_a_private_staging_dir
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      first = prepare(env, dir)
      # 不 release，模拟另一个 job 正在装。

      second = prepare(env, dir)
      assert_equal "false", second["hit"]
      assert_equal "", second["lock"], "抢不到锁就不该声称持锁"
      assert_includes second["destination"].to_s, "crystal-staging-",
        "抢不到锁时应装到私有暂存目录，避免交叉写入"
      assert_includes second["destination"].to_s, env["RUNNER_TEMP"]
      assert_equal VERSION, second["version"], "暂存路径也要把版本号传下去"

      release(first, env)
    end
  end

  # 锁还在有效期内时，即使缓存目录「看起来」完整也不读：持有者可能正往里写，
  # 此刻看到的不是完整工具链。
  def test_fresh_lock_blocks_reading_an_apparently_complete_cache
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      first = prepare(env, dir)
      fake_toolchain(first["destination"], VERSION)
      File.write(File.join(first["destination"], ".sebas-complete"), "#{VERSION}\n")

      second = prepare(env, dir)
      assert_equal "false", second["hit"]
      assert_includes second["destination"].to_s, "crystal-staging-"

      release(first, env)
    end
  end

  # 真正的时序：首次检查时缓存是坏的，拿到锁之后才变好。
  #
  # BASH_ENV 注入一个 mkdir 包装函数，在脚本 `mkdir "$lock"` 那一刻把准备好的
  # 工具链搬进缓存目录，模拟「别人刚装完」。去掉拿锁后的重判，这个用例会看见
  # 目录被删、hit=false。
  def test_lock_holder_rechecks_the_cache_after_acquiring_the_lock
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      root = File.join(cache_root(env), VERSION)
      lock = "#{root}.lock"

      # 半截缓存（无完成标记），保证首次检查必然未命中，且没有锁。
      fake_toolchain(root, VERSION)

      # 另一个 job「装好并打了标记」的样子。
      seed = File.join(dir, "seed")
      fake_toolchain(seed, VERSION)
      File.write(File.join(seed, ".sebas-complete"), "#{VERSION}\n")

      hook = File.join(dir, "hook.sh")
      File.write(hook, <<~SH)
        mkdir() {
          if [ "$1" = "#{lock}" ] && [ ! -e "#{root}/.sebas-complete" ]; then
            command cp -a "#{seed}/." "#{root}/"
          fi
          command mkdir "$@"
        }
      SH

      out, status = run_script(["prepare"], env.merge("BASH_ENV" => hook))
      assert status.success?, out
      result = outputs(dir)
      assert_equal "true", result["hit"], "拿锁后必须重判缓存：等锁期间别人可能刚装完"
      assert_equal "", result["lock"], "复用路径不能留着锁"
      assert File.directory?(File.join(root, "src")), "刚装好的工具链不能被删掉"
      assert_equal [File.join(root, "bin"), File.join(root, "embedded", "bin")],
        path_lines(dir).reverse, "命中后要把缓存目录写进 GITHUB_PATH"
    end
  end

  def test_stale_lock_is_taken_over
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      lock = "#{File.join(cache_root(env), VERSION)}.lock"
      FileUtils.mkdir_p(lock)
      File.write(File.join(lock, "owner"), "dead-job")
      old = Time.now - 3600
      File.utime(old, old, lock)

      result = prepare(env, dir)
      assert_equal lock, result["lock"], "超过 TTL 的锁应被接管"
      refute_equal "dead-job", result["owner"]
      assert_equal result["owner"], File.read(File.join(lock, "owner")).strip
      refute File.exist?("#{lock}.takeover"), "接管令牌用完要清掉"
    end
  end

  # 接管本身必须互斥：另一个 job 已经拿着接管令牌时，本 job 只能退到私有目录，
  # 绝不能动那把旧锁——否则两个 job 会同时成为持有者，一起往 $root 写。
  def test_takeover_is_mutually_exclusive
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      lock = "#{File.join(cache_root(env), VERSION)}.lock"
      FileUtils.mkdir_p(lock)
      File.write(File.join(lock, "owner"), "dead-job")
      old = Time.now - 3600
      File.utime(old, old, lock)
      # 另一个 job 正在接管。
      FileUtils.mkdir_p("#{lock}.takeover")

      result = prepare(env, dir)
      assert_equal "", result["lock"], "抢不到接管令牌就不能成为持有者"
      assert_includes result["destination"].to_s, "crystal-staging-"
      assert_equal "dead-job", File.read(File.join(lock, "owner")).strip,
        "旧锁必须原样留着，交给正在接管的那个 job"
    end
  end

  def test_bypassed_takeover_falls_back_instead_of_deleting_the_new_lock
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      lock = "#{File.join(cache_root(env), VERSION)}.lock"
      FileUtils.mkdir_p(lock)
      File.write(File.join(lock, "owner"), "dead-job")
      old = Time.now - 3600
      File.utime(old, old, lock)

      # 在脚本读到 owner 之后、真正动手之前，别的 job 抢先接管并重建了新锁。
      hook = File.join(dir, "hook.sh")
      File.write(hook, <<~SH)
        mkdir() {
          if [ "$1" = "#{lock}.takeover" ]; then
            command rm -rf "#{lock}"
            command mkdir "#{lock}"
            printf 'winner\\n' > "#{lock}/owner"
          fi
          command mkdir "$@"
        }
      SH

      out, status = run_script(["prepare"], env.merge("BASH_ENV" => hook))
      assert status.success?, out
      result = outputs(dir)
      assert_equal "", result["lock"], "owner 变了就不能删锁，只能退到私有目录"
      assert_includes result["destination"].to_s, "crystal-staging-"
      assert File.directory?(lock), "赢家的新锁必须留着"
    end
  end

  def test_fresh_lock_is_respected
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      lock = "#{File.join(cache_root(env), VERSION)}.lock"
      FileUtils.mkdir_p(lock)

      result = prepare(env, dir)
      assert_equal "", result["lock"], "新鲜锁不能被抢"
      assert_includes result["destination"].to_s, "crystal-staging-"
    end
  end

  # 本 job 被强杀 → 锁被 TTL 接管 → 别的 job 拿着新锁在装。此时旧 job 的
  # release 绝不能删掉这把新锁，也不该替对方打完成标记。
  #
  # fixture 必须是「内容物完整、安装步骤也报成功」的：否则 installed_ok 或
  # 安装结论任一环会先拦住写标记，断言就无法证明是 owner 检查在起作用。
  def test_release_leaves_a_lock_taken_over_by_another_job
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      first = prepare(env, dir)
      lock = first["lock"]
      # 完整工具链，但故意不调用 release —— 交给下面的「非持有者」release。
      fake_toolchain(first["destination"], VERSION)

      # 模拟接管：owner 换人（真实路径是 TTL 过期后由另一个 job 重建）。
      File.write(File.join(lock, "owner"), "another-job")

      out, status = release(first, env)
      assert status.success?, "release 不该因为不是自己的锁而失败"
      assert File.directory?(lock), "别的 job 的锁必须留着"
      refute File.exist?(File.join(first["destination"], ".sebas-complete")),
        "不是自己的锁，就不该替对方写完成标记"
      assert_includes out, "no longer owned"
    end
  end

  def test_release_removes_its_own_lock
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      result = prepare(env, dir)
      assert File.directory?(result["lock"])

      release(result, env)
      refute File.exist?(result["lock"]), "自己的锁应被清掉（含 owner 文件）"
    end
  end

  # 安装半途失败（比如磁盘满、解压中断）时 release 照样会跑：不能给半成品
  # 盖章，否则下一个 job 会拿它当好的用，从此一直编译失败。
  def test_release_does_not_mark_an_incomplete_install
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      result = prepare(env, dir)
      # 装了一半：只有 bin，没有 embedded 与标准库。
      FileUtils.mkdir_p(File.join(result["destination"], "bin"))

      out, status = release(result, env)
      assert status.success?, out
      refute File.exist?(File.join(result["destination"], ".sebas-complete")),
        "半成品不能有完成标记"
      assert_includes out, "not usable"

      # 下一个 job 应当判为未命中并重装。
      second = prepare(env, dir)
      assert_equal "false", second["hit"]
    end
  end

  # install-crystal 的 Linux 分支并行装 apt 依赖与工具链：依赖装失败时包可能
  # 已经解好。只看内容物就会把「这台机器缺 libssl-dev」固化进缓存——之后每个
  # job 都跳过安装，一直编译失败。
  def test_release_does_not_mark_when_the_install_step_failed
    Dir.mktmpdir do |dir|
      env = env_for(dir, "RUNNER_OS" => "Linux")
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      result = prepare(env, dir)
      fake_toolchain(result["destination"], VERSION, os: "Linux")

      out, status = release(result, env, installed: "false")
      assert status.success?, out
      refute File.exist?(File.join(result["destination"], ".sebas-complete")),
        "安装步骤失败就不能盖章，哪怕文件看起来齐了"
      refute File.exist?(result["lock"]), "失败路径也要放锁"
      assert_includes out, "did not succeed"
    end
  end

  # release 在「读 owner → 删锁」之间被接管插入时，会删掉接管方的新锁。
  # 所以它必须与接管共用 takeover 令牌：拿不到令牌就保留锁，交给 TTL。
  def test_release_yields_to_a_takeover_in_progress
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      result = prepare(env, dir)
      # 另一个 job 正拿着 takeover 令牌接管这把锁。
      FileUtils.mkdir_p("#{result["lock"]}.takeover")

      out, status = release(result, env)
      assert status.success?, out
      assert File.directory?(result["lock"]), "令牌被占时不能删锁"
      assert_includes out, "being taken over"
    end
  end

  # 盖章同理：读 owner、跑校验、写标记这三步之间若被接管插入，标记会写进接管
  # 方正在重建的目录，随后被当成完好缓存长期复用。
  def test_completion_marker_is_not_written_while_a_takeover_is_in_progress
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      FileUtils.mkdir_p(env["RUNNER_TEMP"])
      result = prepare(env, dir)
      fake_toolchain(result["destination"], VERSION)
      FileUtils.mkdir_p("#{result["lock"]}.takeover")

      out, status = release(result, env)
      assert status.success?, out
      refute File.exist?(File.join(result["destination"], ".sebas-complete")),
        "接管进行中时不能盖章"
      assert_includes out, "being taken over"
    end
  end
end
