# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

# .coderabbit.yaml 的结构校验（#116）。
# 这份配置只影响 review 提示质量，不是门禁；但路径写错会让指令静默失效，
# 所以用测试锁住关键结构。
class CoderabbitConfigTest < Minitest::Test
  PATH = File.expand_path("../.coderabbit.yaml", __dir__)

  def config
    @config ||= YAML.safe_load_file(PATH)
  end

  def test_file_exists_and_parses
    assert File.exist?(PATH), ".coderabbit.yaml 缺失"
    assert_kind_of Hash, config
  end

  def test_declares_schema_version
    assert_equal 2, config["version"]
  end

  def test_language_is_chinese
    # 仓库正文用中文，review 也应按中文输出。
    assert_equal "zh-CN", config["language"]
  end

  def test_review_profile_is_valid
    assert_includes %w[quiet chill assertive], config.dig("reviews", "profile")
  end

  def test_path_instructions_cover_critical_dirs
    paths = config.dig("reviews", "path_instructions").map { |p| p["path"] }
    must_cover = ["src/**/*.cr", "spec/**/*.cr", "docs/**/*.md",
      "tools/**/*.rb", ".github/workflows/**"]
    must_cover.each do |pattern|
      assert_includes paths, pattern, "缺少 #{pattern} 的审阅指令"
    end
  end

  def test_each_instruction_is_non_empty
    config.dig("reviews", "path_instructions").each do |entry|
      refute_nil entry["path"]
      refute_empty entry["instructions"].to_s.strip, "#{entry["path"]} 的指令为空"
    end
  end

  def test_archive_dirs_are_filtered_out
    filters = config.dig("reviews", "path_filters")
    # 历史存档含预期内的行号锚，不该作为 review 噪音。
    assert_includes filters, "!docs/design/review/**"
    assert_includes filters, "!docs/design/research/**"
  end

  def test_workflow_instructions_mention_sha_pinning
    entry = config.dig("reviews", "path_instructions").find { |p| p["path"] == ".github/workflows/**" }
    refute_nil entry
    assert_includes entry["instructions"], "SHA",
      "workflow 指令必须提到 SHA 钉版（这是仓库红线）"
  end

  def test_docs_instructions_forbid_line_anchors
    entry = config.dig("reviews", "path_instructions").find { |p| p["path"] == "docs/**/*.md" }
    refute_nil entry
    assert_includes entry["instructions"], "行号",
      "文档指令必须提到不用行号锚"
  end

  def test_incremental_review_enabled
    # 仓库流程依赖每推一个 commit 重新审来收敛 thread。
    assert_equal true, config.dig("reviews", "auto_review", "auto_incremental_review")
  end
end
