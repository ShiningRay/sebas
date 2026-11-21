# frozen_string_literal: true

# 版本守卫回归：低版本必须在加载任何业务代码之前被拒绝，
# 且报错要给出可执行的修复方式，而不是内部 NameError。
require "minitest/autorun"
require "open3"
require "tmpdir"

class RubyVersionGuardTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
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
  end

  def test_refuses_with_actionable_message
    Dir.mktmpdir do |dir|
      simulated = File.join(dir, "sim.rb")
      source = File.read(ENTRY, encoding: "UTF-8")
        .sub("if Gem::Version.new(RUBY_VERSION) < Gem::Version.new(REQUIRED_RUBY)", "if true")
      File.write(simulated, source, encoding: "UTF-8")

      out, err, status = Open3.capture3(RbConfig.ruby, simulated, "roles", "--one-line", chdir: ROOT)
      assert_equal 2, status.exitstatus, "低版本必须以退出码 2 拒绝"
      message = out + err
      assert_includes message, "需要 Ruby >= #{required_minor}"
      assert_includes message, ".ruby-version"
      assert_includes message, pinned, "提示里应给出 .ruby-version 的具体版本"
      assert_includes message, "rbenv"
      refute_includes message, "uninitialized constant", "不得泄漏内部错误"
    end
  end

  def test_runs_on_supported_ruby
    skip "本机 Ruby 低于 #{ABSOLUTE_MINIMUM}" if Gem::Version.new(RUBY_VERSION) < ABSOLUTE_MINIMUM

    out, err, status = Open3.capture3(RbConfig.ruby, ENTRY, "version", chdir: ROOT)
    assert status.success?, "受支持版本应正常运行：#{err}"
    assert_includes out, "sebas-process"
  end
end
