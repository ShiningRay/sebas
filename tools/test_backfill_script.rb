# frozen_string_literal: true

# backfill_m4_automation.rb 的幂等性回归。
# 脚本修改线上 issue body，必须保证重复运行不改变结果。
require "minitest/autorun"

class BackfillScriptTest < Minitest::Test
  SCRIPT = File.expand_path("backfill_m4_automation.rb", __dir__)

  # 只加载纯函数，不执行文件末尾的 PLAN 循环。
  def self.load_helpers
    source = File.read(SCRIPT, encoding: "UTF-8")
    [source, source[/^FENCE = (.+)$/, 1], source[/^def with_block.*?^end$/m]]
  end

  SOURCE, FENCE_SRC, WITH_BLOCK = load_helpers
  FENCE = eval(FENCE_SRC) # rubocop:disable Security/Eval
  eval(WITH_BLOCK) # rubocop:disable Security/Eval

  BLOCK = "```json automation\n{\"schema\":1,\"kind\":\"work_package\"}\n```\n"

  def test_idempotent_on_existing_block
    first = with_block("标题\n\n## Automation\n\n#{BLOCK}", BLOCK)
    second = with_block(first, BLOCK)
    assert_equal first, second
    assert_equal 1, second.scan(/^## Automation/).length
    assert_equal 1, second.scan(/```json automation/).length
  end

  def test_collapses_duplicate_blocks
    body = "A\n## Automation\n\n#{BLOCK}## Automation\n\n#{BLOCK}"
    out = with_block(body, BLOCK)
    assert_equal 1, out.scan(/```json automation/).length
    assert_equal 1, out.scan(/^## Automation/).length
  end

  def test_handles_cr_only_body
    body = "标题\r\r## Automation\r\r```json automation\r{\"k\":1}\r```\r"
    out = with_block(body, BLOCK)
    assert_equal 1, out.scan(/```json automation/).length
    refute_includes out, "\"k\":1"
  end

  def test_handles_crlf_body
    body = "标题\r\n\r\n## Automation\r\n\r\n```json automation\r\n{\"k\":1}\r\n```\r\n"
    out = with_block(body, BLOCK)
    assert_equal 1, out.scan(/```json automation/).length
    refute_includes out, "\r"
  end

  def test_preserves_surrounding_content
    out = with_block("开头段落\n\n## 其他\n\n内容", BLOCK)
    assert_includes out, "开头段落"
    assert_includes out, "## 其他"
    assert_includes out, "内容"
  end
end
