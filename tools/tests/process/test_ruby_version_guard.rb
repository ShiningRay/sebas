# frozen_string_literal: true

# 版本守卫回归：低版本必须在加载任何业务代码之前被拒绝，
# 且报错要给出可执行的修复方式，而不是内部 NameError。

require_relative "../support/boot"

class RubyVersionGuardTest < Minitest::Test
  ROOT = RepoPaths::ROOT
  ENTRY = File.join(ROOT, "tools", "sebas-process")
  VERSION_FILE = File.join(ROOT, ".ruby-version")

  # 代码下限：Data.define 自 3.2 起可用。仓库实际钉的版本可以更高。
  ABSOLUTE_MINIMUM = Gem::Version.new("3.2")

  def pinned
    File.read(VERSION_FILE, encoding: "UTF-8").strip
  end

  def required_minor
    pinned.split(".").first(2).join(".")
  end

  def test_version_file_exists_and_pins_supported_ruby
    assert File.exist?(VERSION_FILE), "缺少 .ruby-version"
    assert_match(/\A\d+\.\d+\.\d+\z/, pinned)
    assert Gem::Version.new(pinned) >= ABSOLUTE_MINIMUM,
      ".ruby-version 必须 >= #{ABSOLUTE_MINIMUM}（代码使用 Data.define），实际 #{pinned}"
  end

  def test_guard_runs_before_loading_library
    source = File.read(ENTRY, encoding: "UTF-8")
    guard = source.index("Gem::Version.new(RUBY_VERSION) <")
    load = source.index('require_relative "agents/lib/sebas_agents"')
    refute_nil guard, "入口缺少版本守卫"
    refute_nil load
    assert guard < load, "版本守卫必须在加载业务代码之前"
  end

  # 版本要求只能有一个来源：入口必须从 .ruby-version 推导，不能写死常量。
  def test_entry_reads_the_pinned_version_instead_of_hardcoding
    source = File.read(ENTRY, encoding: "UTF-8")
    assert_includes source, ".ruby-version", "入口应从 .ruby-version 读取版本"
    refute_match(/REQUIRED_RUBY\s*=\s*"\d+\.\d+"/,
      source, "不得把版本号写死，否则与 .ruby-version 会漂移")
    assert_equal File.join(ROOT, ".ruby-version"), entry_version_file,
      "VERSION_FILE 必须指向仓库根；__dir__ 是 tools/，漏掉 ../ 会静默退化"
  end

  # 回归：曾在入口里写成 File.expand_path(".ruby-version", __dir__)，
  # 实际查找 tools/.ruby-version，文件永远不存在，防守卫与 pin 脱钩。
  def test_entry_version_path_points_at_repo_root
    assert File.exist?(entry_version_file), "入口解析到的版本文件不存在：#{entry_version_file}"
    assert_equal pinned, File.read(entry_version_file, encoding: "UTF-8").strip
  end

  # 真正按入口的逻辑解析：取入口里的 VERSION_FILE 表达式求值，而不是照抄常量。
  # 入口的 __dir__ 恒为 tools/；这里把它替换成实际目录字符串，再用 clean binding 求值。
  def entry_version_file
    @entry_version_file ||= begin
      source = File.read(ENTRY, encoding: "UTF-8")
      expression = source[/^VERSION_FILE = (.+)$/, 1]
      raise "入口缺少 VERSION_FILE 定义" unless expression

      tools_dir = File.join(ROOT, "tools")
      resolved = expression.gsub("__dir__", tools_dir.inspect)
      TOPLEVEL_BINDING.eval(resolved) # rubocop:disable Security/Eval -- 受控：只求值仓库内常量
    end
  end

  def test_refuses_with_actionable_message
    # 模拟脚本必须放在 tools/ 下（并带同目录的 .ruby-version），
    # 才能复现入口真实的路径解析；放到 tmpdir 会触发「缺件」分支。
    with_simulated_entry(root: ROOT) do |script|
      out, err, status = Open3.capture3(RbConfig.ruby, script, "roles", "--one-line", chdir: ROOT)
      assert_equal 2, status.exitstatus, "低版本必须以退出码 2 拒绝"
      message = out + err
      assert_includes message, "需要 Ruby >= #{required_minor}"
      assert_includes message, ".ruby-version"
      assert_includes message, pinned, "提示里应给出 .ruby-version 的具体版本"
      assert_includes message, "rbenv"
      refute_includes message, "uninitialized constant", "不得泄漏内部错误"
    end
  end

  # 缺 .ruby-version 时必须报错退出，而不是用硬编码兜底悄悄降级。
  def test_missing_version_file_fails_loudly
    Dir.mktmpdir do |dir|
      simulated = File.join(dir, "sim.rb")
      source = File.read(ENTRY, encoding: "UTF-8")
        .sub("if Gem::Version.new(RUBY_VERSION) < Gem::Version.new(REQUIRED_RUBY)", "if true")
      File.write(simulated, source, encoding: "UTF-8")

      out, err, status = Open3.capture3(RbConfig.ruby, simulated, "version", chdir: ROOT)
      assert_equal 2, status.exitstatus
      assert_includes(out + err, "找不到", "缺件时必须明确报错")
    end
  end

  def test_runs_on_supported_ruby
    # 用的是「配置的下限」，不是代码绝对下限：pin 提到 3.4 后，
    # 3.2/3.3 会被入口正确拒绝（退出码 2），在这里就该跳过而不是失败。
    skip "本机 Ruby #{RUBY_VERSION} 低于配置下限 #{required_minor}" if
      Gem::Version.new(RUBY_VERSION) < Gem::Version.new(required_minor)

    out, err, status = Open3.capture3(RbConfig.ruby, ENTRY, "version", chdir: ROOT)
    assert status.success?, "受支持版本应正常运行：#{err}"
    assert_includes out, "sebas-process"
  end

  private

  # 在 <root>/tools/ 下写一份补丁版入口（比较表达式置真），
  # 让 __dir__ 与真实入口一致。注意：private 之后的 test_* 不会被 Minitest 发现，
  # 所以所有测试方法都必须写在这一行之前。
  def with_simulated_entry(root:)
    tools_dir = File.join(root, "tools")
    script = File.join(tools_dir, "sim_entry.rb")
    source = File.read(ENTRY, encoding: "UTF-8")
      .sub("if Gem::Version.new(RUBY_VERSION) < Gem::Version.new(REQUIRED_RUBY)", "if true")
    File.write(script, source, encoding: "UTF-8")
    yield script
  ensure
    File.delete(script) if script && File.exist?(script)
  end
end
