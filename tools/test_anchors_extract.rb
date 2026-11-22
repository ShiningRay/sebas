# frozen_string_literal: true

# anchors_extract 单测（#121）。全部基于 tmpdir，不触网。
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "anchors_extract"

class AnchorsExtractTest < Minitest::Test
  def with_repo
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      FileUtils.mkdir_p(File.join(dir, "docs"))
      yield dir
    end
  end

  def write(root, relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content, encoding: "UTF-8")
  end

  # --- 抽取 ---

  def test_extracts_single_reference
    with_repo do |dir|
      write(dir, "src/x.cr", "第一行\n目标行\n第三行\n")
      write(dir, "docs/a.md", "见 src/x.cr:2 的实现。\n")

      anchors, skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty problems
      assert_empty skipped
      assert_equal 1, anchors.length
      assert_equal "src/x.cr", anchors[0]["file"]
      assert_equal 2, anchors[0]["line"]
      assert_equal "目标行", anchors[0]["content"]
    end
  end

  def test_extracts_range_endpoints
    with_repo do |dir|
      write(dir, "src/x.cr", (1..20).map { |i| "行#{i}\n" }.join)
      write(dir, "docs/a.md", "见 src/x.cr:3-6 的区间。\n")

      anchors, = AnchorExtractor.extract(["docs/a.md"], root: dir)
      # 只核验端点，不逐行展开：区间表达「这一带」。
      assert_equal [3, 6], anchors.map { |anchor| anchor["line"] }.sort
    end
  end

  def test_extracts_comma_separated
    with_repo do |dir|
      write(dir, "src/x.cr", (1..30).map { |i| "行#{i}\n" }.join)
      write(dir, "docs/a.md", "见 src/x.cr:5,8-10。\n")

      anchors, = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_equal [5, 8, 10], anchors.map { |anchor| anchor["line"] }.sort
    end
  end

  # 存档目录里的外部项目引用：跳过，不判错。
  def test_skips_external_paths_in_archive_dirs
    with_repo do |dir|
      write(dir, "docs/design/research/a.md", "参考 src/autobot/cli/gateway.cr:76 的设计。\n")

      anchors, skipped, problems = AnchorExtractor.extract(["docs/design/research/a.md"], root: dir)
      assert_empty anchors
      assert_empty problems, "存档目录的外部路径不得判错"
      assert_equal 1, skipped.length
      assert_includes skipped[0]["ref"], "src/autobot/cli/gateway.cr:76"
    end
  end

  # 当前文档引用不存在的本地文件：必须报错（CodeRabbit Major）。
  # 否则文档引用的源文件被删除或拼错时会被静默放过。
  def test_reports_missing_local_file_in_current_docs
    with_repo do |dir|
      write(dir, "docs/a.md", "见 src/deleted.cr:12。\n")

      anchors, skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty anchors
      assert_empty skipped, "当前文档不得把缺失文件当外部引用跳过"
      assert_equal 1, problems.length
      assert_includes problems[0], "本仓库没有该文件"
    end
  end

  # 显式输入的 markdown 不存在：报错，不能生成空清单冒充成功。
  def test_reports_missing_input_markdown
    with_repo do |dir|
      write(dir, "src/x.cr", "内容\n")
      _anchors, _skipped, problems = AnchorExtractor.extract(["docs/typo.md"], root: dir)
      assert_equal 1, problems.length
      assert_includes problems[0], "输入文件不存在"
    end
  end

  # 无扩展名的脚本引用也要抽取（tools/sebas-process:123）。
  def test_extracts_extensionless_script_reference
    with_repo do |dir|
      write(dir, "tools/sebas-process", "#!/usr/bin/env ruby\n第二行\n")
      write(dir, "docs/a.md", "见 tools/sebas-process:2。\n")

      anchors, _skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty problems
      assert_equal 1, anchors.length
      assert_equal "tools/sebas-process", anchors[0]["file"]
      assert_equal "第二行", anchors[0]["content"]
    end
  end

  # `./src/x.cr:12` 与 `src/x.cr:12` 必须等价（CodeRabbit）。
  def test_normalizes_dot_slash_prefix
    with_repo do |dir|
      write(dir, "src/x.cr", "一行\n二行\n")
      write(dir, "docs/a.md", "见 ./src/x.cr:2。\n")

      anchors, _skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty problems
      assert_equal 1, anchors.length, "./ 前缀不应导致漏检"
      assert_equal "src/x.cr", anchors[0]["file"]
    end
  end

  def test_dot_slash_out_of_range_is_reported
    with_repo do |dir|
      write(dir, "src/x.cr", "只有一行\n")
      write(dir, "docs/a.md", "见 ./src/x.cr:99。\n")

      _anchors, _skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_equal 1, problems.length, "./ 前缀下越界也必须被发现"
    end
  end

  # 指向空行：无法逐字比对，也不是漂移信号，记 skipped。
  def test_skips_blank_line_targets
    with_repo do |dir|
      write(dir, "src/x.cr", "第一行\n\n第三行\n")
      write(dir, "docs/a.md", "见 src/x.cr:2。\n")

      anchors, skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty anchors
      assert_empty problems
      assert_equal "指向空行", skipped[0]["reason"]
    end
  end

  def test_reports_out_of_range_as_problem
    with_repo do |dir|
      write(dir, "src/x.cr", "只有一行\n")
      write(dir, "docs/a.md", "见 src/x.cr:999。\n")

      anchors, _skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty anchors
      assert_equal 1, problems.length
      assert_includes problems[0], "只有 1 行"
    end
  end

  def test_ignores_non_tracked_prefixes
    with_repo do |dir|
      write(dir, "docs/a.md", "版本 1.2:3 与 foo/bar.cr:1 都不该被抽取。\n")

      anchors, skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty anchors
      assert_empty skipped
      assert_empty problems
    end
  end

  # URL 里的伪引用（查询参数/片段）不得被当成源码锚点。
  def test_ignores_references_inside_urls
    with_repo do |dir|
      write(dir, "docs/a.md", <<~MD)
        见 [搜索](https://example.org/search?q=src/remote.cr:999) 与
        https://example.org/page#src/other.cr:42 两个链接。
      MD

      anchors, skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty anchors
      assert_empty skipped
      assert_empty problems, "URL 内的伪引用不得让门禁失败"
    end
  end

  # URL 剥离不能误伤同行的独立源码引用。
  def test_still_extracts_real_reference_next_to_url
    with_repo do |dir|
      write(dir, "src/x.cr", "目标行\n")
      write(dir, "docs/a.md", "见 https://example.org/a?q=src/none.cr:9 与 src/x.cr:1。\n")

      anchors, _skipped, problems = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_empty problems
      assert_equal 1, anchors.length, "URL 之外的独立引用仍须核验"
      assert_equal "src/x.cr", anchors[0]["file"]
    end
  end

  def test_dedupe_keeps_one_per_file_line
    with_repo do |dir|
      write(dir, "src/x.cr", "一行\n二行\n")
      write(dir, "docs/a.md", "见 src/x.cr:1 与 src/x.cr:1 重复。\n")

      anchors, = AnchorExtractor.extract(["docs/a.md"], root: dir)
      assert_equal 2, anchors.length
      assert_equal 1, AnchorExtractor.dedupe(anchors).length
    end
  end

  # --- run 层 ---

  def test_run_writes_output_file
    with_repo do |dir|
      write(dir, "src/x.cr", "内容\n")
      write(dir, "docs/a.md", "见 src/x.cr:1。\n")
      out_path = File.join(dir, "anchors.json")

      code = AnchorExtractor.run(
        ["--output", out_path, "docs/a.md"], root: dir,
        out: StringIO.new, err: StringIO.new
      )
      assert_equal 0, code
      data = JSON.parse(File.read(out_path, encoding: "UTF-8"))
      assert_equal 1, data.length
      assert_equal "内容", data[0]["content"]
    end
  end

  def test_run_refuses_when_out_of_range
    with_repo do |dir|
      write(dir, "src/x.cr", "一行\n")
      write(dir, "docs/a.md", "见 src/x.cr:50。\n")
      err = StringIO.new

      code = AnchorExtractor.run(["docs/a.md"], root: dir, out: StringIO.new, err: err)
      assert_equal 1, code, "越界必须 fail-closed"
      assert_includes err.string, "行号越界"
    end
  end

  def test_run_requires_paths
    err = StringIO.new
    code = AnchorExtractor.run([], root: Dir.pwd, out: StringIO.new, err: err)
    assert_equal 2, code
    assert_includes err.string, "至少需要一个"
  end
end
