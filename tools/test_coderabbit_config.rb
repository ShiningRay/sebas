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

  def test_workflow_instructions_require_sha_pinning_and_whitelist
    entry = config.dig("reviews", "path_instructions").find { |p| p["path"] == ".github/workflows/**" }
    refute_nil entry
    text = entry["instructions"]
    # 断言完整要求，而不是「是否提到 SHA」——后者在写「无需 SHA 钉版」时也会通过。
    assert_match(/必须 SHA 钉版/, text, "workflow 指令必须强制要求 SHA 钉版")
    assert_match(/白名单/, text, "workflow 指令必须提到 action 白名单")
    refute_match(/无需\s*SHA|不要求\s*SHA|允许.*未钉版/, text, "不得出现放宽 SHA 钉版的表述")
  end

  def test_docs_instructions_forbid_line_anchors
    entry = config.dig("reviews", "path_instructions").find { |p| p["path"] == "docs/**/*.md" }
    refute_nil entry
    text = entry["instructions"]
    assert_match(/(不要|禁止|不得)用行号/, text, "文档指令必须禁用行号锚")
    refute_match(/允许(使用)?行号/, text, "不得出现允许行号锚的表述")
  end

  def test_incremental_review_enabled
    # 仓库流程依赖每推一个 commit 重新审来收敛 thread。
    assert_equal true, config.dig("reviews", "auto_review", "auto_incremental_review")
  end

  def test_auto_pause_threshold_disabled
    # 默认 5 会在达到阈值后暂停自动审阅，与「push 后等再扫」冲突。
    assert_equal 0, config.dig("reviews", "auto_review", "auto_pause_after_reviewed_commits")
  end

  def test_noise_reduction_lives_in_prompt_field
    # YAML 注释不会进入审阅提示；降噪要求必须写在 tone_instructions 里。
    tone = config["tone_instructions"].to_s
    assert_match(/合并成一条/, tone, "同类意见合并的要求必须在 tone_instructions 中")
  end
end
