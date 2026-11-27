# frozen_string_literal: true

# .github/agents.yml 的 `capacity` 键（recovery §5 / Q3）。
#
# 缺键即 1——行为与单卡容量一致；正整数生效；非法值 fail-closed，
# 不静默回落默认。浮点尤其要拒：Integer 会截断 2.5 → 2，
# 「以为提了容量」的配置会假生效。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class CapacityConfigTest < Minitest::Test
  def write_config(dir, content)
    gh_dir = File.join(dir, ".github")
    Dir.mkdir(gh_dir) unless Dir.exist?(gh_dir)
    File.write(File.join(gh_dir, "agents.yml"), content, encoding: "UTF-8")
  end

  def read_capacity(dir)
    gateway = SebasAgents::GithubGateway.new(nil, repo: "o/r")
    Dir.chdir(dir) { gateway.capacity }
  end

  def test_capacity_defaults_to_one_without_key
    Dir.mktmpdir do |dir|
      write_config(dir, "maintainers:\n  - ShiningRay\n")
      assert_equal 1, read_capacity(dir)
    end
  end

  def test_capacity_reads_explicit_value
    Dir.mktmpdir do |dir|
      write_config(dir, "maintainers:\n  - ShiningRay\ncapacity: 2\n")
      assert_equal 2, read_capacity(dir)
    end
  end

  def test_capacity_missing_file_defaults_to_one
    Dir.mktmpdir do |dir|
      assert_equal 1, read_capacity(dir)
    end
  end

  def test_capacity_rejects_non_integer
    Dir.mktmpdir do |dir|
      write_config(dir, "maintainers:\n  - ShiningRay\ncapacity: many\n")
      assert_raises(SebasAgents::CommandError) { read_capacity(dir) }
    end
  end

  def test_capacity_rejects_non_positive
    Dir.mktmpdir do |dir|
      write_config(dir, "maintainers:\n  - ShiningRay\ncapacity: 0\n")
      assert_raises(SebasAgents::CommandError) { read_capacity(dir) }
    end
  end

  # 显式 null（YAML 空值）与浮点都不是合法容量：Integer 对浮点会截断
  # （2.5→2），静默放行会让「以为提了容量」的配置假生效。
  def test_capacity_rejects_explicit_null
    Dir.mktmpdir do |dir|
      write_config(dir, "maintainers:\n  - ShiningRay\ncapacity:\n")
      assert_raises(SebasAgents::CommandError) { read_capacity(dir) }
    end
  end

  def test_capacity_rejects_float
    Dir.mktmpdir do |dir|
      write_config(dir, "maintainers:\n  - ShiningRay\ncapacity: 2.5\n")
      assert_raises(SebasAgents::CommandError) { read_capacity(dir) }
    end
  end

end
