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

  def test_version_file_exists_and_pins_minimum
    assert File.exist?(VERSION_FILE), "缺少 .ruby-version"
    pinned = File.read(VERSION_FILE, encoding: "UTF-8").strip
    assert_match(/\A\d+\.\d+\.\d+\z/, pinned)
    assert Gem::Version.new(pinned) >= Gem::Version.new("3.2"),
      ".ruby-version 必须 >= 3.2（代码使用 Data.define），实际 #{pinned}"
  end

  def test_guard_runs_before_loading_library
    source = File.read(ENTRY, encoding: "UTF-8")
    guard = source.index("Gem::Version.new(RUBY_VERSION) <")
    load = source.index('require_relative "agents/lib/sebas_agents"')
    refute_nil guard, "入口缺少版本守卫"
    refute_nil load
    assert guard < load, "版本守卫必须在加载业务代码之前"
  end

  def test_refuses_with_actionable_message
    Dir.mktmpdir do |dir|
      simulated = File.join(dir, "sim.rb")
      source = File.read(ENTRY, encoding: "UTF-8")
        .sub("Gem::Version.new(RUBY_VERSION) < Gem::Version.new(REQUIRED_RUBY)", "true")
      File.write(simulated, source, encoding: "UTF-8")

      out, err, status = Open3.capture3(RbConfig.ruby, simulated, "roles", "--one-line", chdir: ROOT)
      assert_equal 2, status.exitstatus, "低版本必须以退出码 2 拒绝"
      message = out + err
      assert_includes message, "需要 Ruby >= 3.2"
      assert_includes message, ".ruby-version"
      assert_includes message, "rbenv"
      refute_includes message, "uninitialized constant", "不得泄漏内部错误"
    end
  end

  def test_runs_on_supported_ruby
    skip "本机 Ruby 低于 3.2" if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.2")

    out, err, status = Open3.capture3(RbConfig.ruby, ENTRY, "version", chdir: ROOT)
    assert status.success?, "受支持版本应正常运行：#{err}"
    assert_includes out, "sebas-process"
  end
end
