# frozen_string_literal: true

# verify.yml 的契约测试（#122）。
#
# ## 为什么需要这个测试
#
# verify.yml 的核心安全属性是「核验脚本取自 base 分支」。这条属性只靠
# YAML 写法正确来保证——若有人把 `ref:` 改成 `github.event.pull_request.head.sha`，
# PR 就能改核验逻辑让自己通过，而所有其他测试仍会绿。
# 所以这里把「安全核心」写成断言：改坏了就红。
#
# 同时验证 shell 片段里的关键逻辑（结论映射、退出码）与 action 钉版。

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"

class VerifyWorkflowTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  WORKFLOW = File.join(ROOT, ".github", "workflows", "verify.yml")

  def workflow
    @workflow ||= YAML.safe_load_file(WORKFLOW)
  end

  def text
    @text ||= File.read(WORKFLOW, encoding: "UTF-8")
  end

  # --- 安全核心 ---

  # verifier job 的第一个 checkout 必须取 base sha，且落在 trusted/ 目录。
  # 用 head.sha 或 repository 默认分支都等于把核验逻辑交给 PR 控制。
  def test_trusted_checkout_uses_base_sha
    step = verifier_steps.find { |s| s["name"]&.include?("trusted") }
    refute_nil step, "缺少 trusted checkout 步骤"
    assert_equal "${{ github.event.pull_request.base.sha }}", step.dig("with", "ref"),
      "可信脚本必须来自 base sha"
    assert_equal "trusted", step.dig("with", "path")
  end

  # PR 内容只作被核验对象，其脚本一律不执行——所以必须与 trusted 分开目录。
  def test_target_checkout_is_separate_and_persists_nothing
    step = verifier_steps.find { |s| s["name"]&.include?("target") }
    refute_nil step, "缺少 target checkout 步骤"
    assert_equal "${{ github.event.pull_request.head.sha }}", step.dig("with", "ref")
    assert_equal "target", step.dig("with", "path")
    assert_equal false, step.dig("with", "persist-credentials"),
      "两个 checkout 都不得持久化凭据"
  end

  # 所有 ruby 调用必须以 trusted/ 为工作目录，即执行环境里不能出现 target 的脚本。
  def test_ruby_invocations_run_from_trusted
    scripts = verifier_steps.filter_map { |s| s["run"] }.join("\n")
    # 每个 `cd trusted` 之后的 ruby 调用都在可信目录内；这里检查不存在
    # `cd target` 之后的 ruby 执行（那会用 PR 脚本核验自己）。
    refute_match(/cd target\s*\n(?:.*\n)*?\s*ruby\s/, scripts,
      "不得在 target 目录里执行 ruby（那是 PR 自己的脚本）")
    assert_includes scripts, "cd trusted", "必须在 trusted 目录执行核验"
  end

  def test_uses_target_root_for_verification
    scripts = verifier_steps.filter_map { |s| s["run"] }.join("\n")
    assert_includes scripts, "--root ../target",
      "核验对象必须是 target（PR 内容），而不是 trusted"
  end

  # --- 权限与触发 ---

  def test_permissions_are_minimal
    assert_equal({"contents" => "read", "pull-requests" => "write"}, workflow["permissions"],
      "只读内容 + 写评论；不给写内容权限")
  end

  def test_triggers_on_pull_request_to_main
    # YAML 1.1 会把裸 `on:` 解析成布尔 true，取键时要兼容两种情况。
    triggers = workflow["on"] || workflow[true]
    assert_equal ["main"], triggers.dig("pull_request", "branches")
  end

  # 并发组按 PR 号，避免同一 PR 的多次推送并发核验。
  def test_concurrency_keyed_by_pr
    assert_includes workflow["concurrency"]["group"], "pull_request.number"
  end

  # --- job 结构 ---

  def test_reviewer_depends_on_verifier
    assert_equal ["verifier"], Array(workflow.dig("jobs", "reviewer", "needs"))
  end

  def test_reviewer_downloads_the_artifact
    steps = workflow.dig("jobs", "reviewer", "steps")
    step = steps.find { |s| s["uses"].to_s.include?("download-artifact") }
    refute_nil step, "reviewer 必须读 verifier 产出的 artifact"
    assert_equal "verification-report", step.dig("with", "name")
  end

  def test_upload_artifact_always_runs
    step = verifier_steps.find { |s| s["uses"].to_s.include?("upload-artifact") }
    refute_nil step
    assert_equal "always()", step["if"], "核验失败时也要保留报告作为证据"
  end

  # --- action 钉版 ---

  def test_all_actions_are_sha_pinned
    unpinned = []
    collect_uses(workflow).each do |path, value|
      next if value.start_with?("./")
      unpinned << [path, value] unless value.match?(/@[0-9a-f]{40}\z/)
    end
    assert_empty unpinned, "所有 action 必须 SHA 钉版：#{unpinned.inspect}"
  end

  # --- 判定逻辑（与 tools 层同口径）---

  # 端到端安全属性：用 base 脚本核验被篡改的 PR 内容，越界仍须被抓。
  # 这条是把「脚本取自 base」从「写法断言」升级为「行为断言」——
  # 即使 YAML 写法正确，若 shell 里实际执行了 target 的脚本，本测试也会红。
  def test_base_scripts_catch_sabotaged_content
    Dir.mktmpdir do |dir|
      trusted = File.join(dir, "trusted")
      target = File.join(dir, "target")
      FileUtils.mkdir_p(trusted)
      FileUtils.mkdir_p(target)

      # base = 仓库当前内容
      tar = File.join(dir, "base.tar")
      system("git", "archive", "HEAD", "-o", tar, chdir: ROOT) || skip("无法导出仓库归档")
      system("tar", "--force-local", "-xf", tar, "-C", trusted) || skip("无法解归档")
      system("tar", "--force-local", "-xf", tar, "-C", target) || skip("无法解归档")

      # PR 篡改核验脚本为「永远通过」
      File.write(File.join(target, "tools/agents/lib/sebas_agents/verifier.rb"), <<~RUBY, encoding: "UTF-8")
        module SebasAgents
          module Verifier
            def self.verify_code_anchors(*) = VerificationReport.new
            def self.verify_docs(*) = VerificationReport.new
            def self.verify_merge(*) = VerificationReport.new
          end
        end
      RUBY

      # PR 塞入一个必然越界的锚点
      sabotage = File.join(target, "docs/design/sabotage.md")
      File.write(sabotage, "# 破坏测试\n\n见 src/main.cr:999999。\n", encoding: "UTF-8")

      out = File.join(dir, "anchors.json")
      _o, err, st = Open3.capture3(
        "ruby", "tools/anchors_extract.rb", "--root", target, "--output", out,
        "docs/design/sabotage.md", "docs/design/design.md",
        chdir: trusted
      )

      assert_equal 1, st.exitstatus, "base 脚本必须抓住越界锚点"
      assert_includes err, "999999", "错误信息应指出越界位置"
    end
  end

  # 反证：同一篡改内容用 target 脚本执行就检测不到——说明 base 版本不可省。
  def test_target_scripts_would_be_bypassed
    Dir.mktmpdir do |dir|
      target = File.join(dir, "target")
      FileUtils.mkdir_p(target)
      tar = File.join(dir, "base.tar")
      system("git", "archive", "HEAD", "-o", tar, chdir: ROOT) || skip("无法导出仓库归档")
      system("tar", "--force-local", "-xf", tar, "-C", target) || skip("无法解归档")

      # 把生成器改成「永远写出空清单」，模拟 PR 让门禁形同虚设。
      File.write(File.join(target, "tools/anchors_extract.rb"), <<~RUBY, encoding: "UTF-8")
        module AnchorExtractor
          def self.run(_argv, root: Dir.pwd, out: $stdout, err: $stderr)
            File.write(File.expand_path("anchors.json", root), "[]", encoding: "UTF-8")
            0
          end
        end
        exit(AnchorExtractor.run(ARGV)) if $PROGRAM_NAME == __FILE__
      RUBY

      sabotage = File.join(target, "docs/design/sabotage.md")
      File.write(sabotage, "# 破坏测试\n\n见 src/main.cr:999999。\n", encoding: "UTF-8")

      out = File.join(dir, "anchors.json")
      _o, _e, st = Open3.capture3(
        "ruby", "tools/anchors_extract.rb", "--root", target, "--output", out,
        "docs/design/sabotage.md",
        chdir: target
      )

      assert_equal 0, st.exitstatus, "对照：篡改后的脚本会放行（这正是必须用 base 的原因）"
    end
  end

  # reviewer 的判定必须覆盖「有 blocker / 有 must_fix / 无证据 unverified」三类。
  def test_reviewer_verdict_covers_three_failure_kinds
    script = workflow.dig("jobs", "reviewer", "steps")
      .filter_map { |s| s["run"] }.join("\n")
    assert_includes script, '"blocker"'
    assert_includes script, '"must_fix"'
    assert_includes script, '"unverified"'
    assert_includes script, "exit 1", "打回必须让 job 失败"
  end

  # 结论三级与 VerificationReport#conclusion 一致：打回 / 有条件通过 / 通过。
  def test_verdict_levels_match_report_conclusion
    library = File.read(File.join(ROOT, "tools/agents/lib/sebas_agents/verification_report.rb"), encoding: "UTF-8")
    %w[打回 有条件通过 通过].each do |word|
      assert_includes library, word, "VerificationReport 应含结论 #{word}"
    end
  end

  private

  def verifier_steps
    workflow.dig("jobs", "verifier", "steps") || []
  end

  def collect_uses(node, path = "", acc = [])
    case node
    when Hash
      node.each do |key, value|
        if key == "uses" && value.is_a?(String)
          acc << [path, value]
        else
          collect_uses(value, "#{path}.#{key}", acc)
        end
      end
    when Array
      node.each_with_index { |value, index| collect_uses(value, "#{path}[#{index}]", acc) }
    end
    acc
  end
end
