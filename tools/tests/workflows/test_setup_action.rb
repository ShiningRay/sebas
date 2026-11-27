# frozen_string_literal: true

# .github/actions/setup 的契约测试（结构层）。
#
# 自托管 runner 上 Crystal 工具链的复用逻辑由 crystal-cache.sh 与 action.yml 的
# 四步编排组成；这里固定 YAML 编排与磁盘布局的形态，改坏了别处不会红。
# 行为层（真跑脚本、锁与接管）见 test_setup_action_behavior.rb。

require_relative "../support/boot"
require_relative "../support/setup_action_helpers"

class SetupActionTest < Minitest::Test
  include SetupActionHelpers

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

end
