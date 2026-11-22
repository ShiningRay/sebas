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
# 行为测试从 workflow 步骤**派生**执行命令（见 derive_anchors_invocation），
# 不手写命令；否则改动 workflow 不会同步改变测试，断言就形同虚设
# （CodeRabbit 在 PR #129 指出：手写命令 + 只查 `cd target` 时，
# `ruby ../target/tools/anchors_extract.rb` 这类写法能骗过全部断言）。
#
# 同时验证 shell 片段里的关键逻辑（结论映射、退出码）与 action 钉版。
#
# 注意：本测试与 workflow 同在 PR 可改范围内，是回归绊线而**非** PR 时控制；
# 阻止 PR 替换 workflow 的独立控制是 pull_request_target + .github/ 审核红线。

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
  #
  # 断言强度（CodeRabbit 指出）：不能只看「有没有 cd target 之后跑 ruby」——
  # 若把调用改成 `ruby ../target/tools/anchors_extract.rb`（路径显式指向 target），
  # 正则检查仍会通过。因此这里同时禁止命令行里出现 `../target` 作为 **可执行脚本路径**
  # （`--root ../target` 是数据参数，必须允许）。
  def test_ruby_invocations_run_from_trusted
    scripts = verifier_steps.filter_map { |s| s["run"] }.join("\n")
    assert_includes scripts, "cd trusted", "必须在 trusted 目录执行核验"

    # 禁止把 target 下的脚本当可执行文件：`ruby <path under target>` 或
    # `ruby ../target/...`。允许 `--root ../target`（数据参数）与 `../out`（输出）。
    offenders = scripts.scan(/ruby\s+[^\n]*\.\.\/target\/[^\s]*\.rb/)
    assert_empty offenders, "不得执行 target 下的脚本：#{offenders.inspect}"
  end

  def test_uses_target_root_for_verification
    scripts = verifier_steps.filter_map { |s| s["run"] }.join("\n")
    assert_includes scripts, "--root ../target",
      "核验对象必须是 target（PR 内容），而不是 trusted"
  end

  # --- 权限与触发 ---

  # 顶层只给 contents: read；写权限必须落在需要的 job 上。
  def test_top_level_permissions_are_read_only
    assert_equal({"contents" => "read"}, workflow["permissions"],
      "顶层不得给写权限（会被所有 job 继承）")
  end

  def test_only_verifier_gets_pull_requests_write
    verifier = workflow.dig("jobs", "verifier", "permissions") || {}
    assert_equal "write", verifier["pull-requests"], "verifier 需要发评论"

    reviewer = workflow.dig("jobs", "reviewer", "permissions") || {}
    refute_equal "write", reviewer["pull-requests"],
      "reviewer 只读判定，不得有 PR 写权限"

    # 发布 job 是唯一例外，且它只发评论。
    publish = workflow.dig("jobs", "publish-verdict", "permissions") || {}
    assert_equal "write", publish["pull-requests"]
    assert_equal "read", publish["contents"], "发布 job 不需要写内容"
  end

  # 入口必须是 pull_request_target：pull_request 下 workflow 定义来自 PR 的
  # merge commit，PR 可改写本文件来绕过核验（CodeRabbit CWE-829）。
  def test_uses_pull_request_target_only
    triggers = workflow["on"] || workflow[true]
    assert triggers.key?("pull_request_target"), "必须用 pull_request_target"
    refute triggers.key?("pull_request"), "不得用 pull_request（workflow 定义来自 PR）"
    assert_equal ["main"], triggers.dig("pull_request_target", "branches")
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

  # 从 workflow 步骤派生「实际执行的脚本 + 工作目录 + 参数」。
  #
  # 为什么不手写命令（CodeRabbit）：手写时把 workflow 改成
  # `ruby ../target/tools/anchors_extract.rb` 而保留 `cd trusted`，
  # 旧断言（只查 cd target）与旧的端到端测试都会照常通过——
  # 测试没跟着 workflow 变，就区分不出「执行 base 脚本」与「执行 target 脚本」。
  def derive_anchors_invocation(run, root:)
    lines = run.lines.map(&:strip)
    cd = lines.find { |l| l.start_with?("cd ") }
    refute_nil cd, "workflow 应显式 cd 到核验目录"
    base = File.expand_path(cd.split(/\s+/)[1], root)

    cmd = lines.find { |l| l.start_with?("ruby ") && l.include?("anchors_extract.rb") }
    refute_nil cmd, "workflow 应调用 anchors_extract.rb"
    tokens = cmd.sub(/\\\z/, "").split
    script = tokens[1]
    # 去掉 shell 变量展开（"${docs[@]}"），其余是静态参数
    args = tokens[2..].to_a.reject { |t| t.include?("${") }
    {base: base, script: File.expand_path(script, base), args: args}
  end

  # 派生出的脚本路径必须落在 base checkout 内。
  def assert_script_is_trusted(invocation, trusted_root)
    assert invocation[:script].start_with?(File.expand_path(trusted_root)),
      "实际执行的脚本必须位于 base checkout 内，实际为 #{invocation[:script]}"
  end

  # 反证：把命令改成显式指向 target 时，上面的断言必须失败——
  # 否则断言就无法区分「base 脚本」与「target 脚本」。
  def test_derivation_catches_target_script_path
    tampered = <<~SH
      mapfile -d '' -t docs < <(cd target && git ls-files -z 'docs/**/*.md')
      cd trusted
      ruby ../target/tools/anchors_extract.rb --root ../target --output ../out/anchors.json "${docs[@]}"
    SH

    # 在假 root 下派生（不需要真实目录，只做路径解析）
    inv = derive_anchors_invocation(tampered, root: "/repo")
    refute inv[:script].start_with?("/repo/trusted"),
      "篡改为 ../target/... 后应解析到 target 内"

    error = assert_raises(Minitest::Assertion) do
      assert_script_is_trusted(inv, "/repo/trusted")
    end
    assert_includes error.message, "/repo/target/tools/anchors_extract.rb"
  end

  # 端到端安全属性：用 base 脚本核验被篡改的 PR 内容，越界仍须被抓。
  # 命令由 workflow 派生，篡改的组件是 workflow 实际调用的 anchors_extract.rb。
  def test_base_scripts_catch_sabotaged_content
    Dir.mktmpdir do |dir|
      trusted = File.join(dir, "trusted")
      target = File.join(dir, "target")
      out_dir = File.join(dir, "out")
      [trusted, target, out_dir].each { |d| FileUtils.mkdir_p(d) }

      tar = File.join(dir, "base.tar")
      system("git", "archive", "HEAD", "-o", tar, chdir: ROOT) || skip("无法导出仓库归档")
      system("tar", "--force-local", "-xf", tar, "-C", trusted) || skip("无法解归档")
      system("tar", "--force-local", "-xf", tar, "-C", target) || skip("无法解归档")

      # 篡改 workflow 实际调用的组件
      File.write(File.join(target, "tools/anchors_extract.rb"), <<~RUBY, encoding: "UTF-8")
        module AnchorExtractor
          def self.run(*) = 0
        end
        exit(AnchorExtractor.run(ARGV)) if $PROGRAM_NAME == __FILE__
      RUBY

      File.write(File.join(target, "docs/design/sabotage.md"),
        "# 破坏测试\n\n见 src/main.cr:999999。\n", encoding: "UTF-8")

      invocation = derive_anchors_invocation(anchors_evidence_step["run"], root: dir)
      assert_script_is_trusted(invocation, trusted)

      _o, err, st = Open3.capture3(
        "ruby", invocation[:script], *materialize(invocation[:args], target:, out_dir:),
        "docs/design/sabotage.md", "docs/design/design.md",
        chdir: invocation[:base]
      )

      assert_equal 1, st.exitstatus, "base 脚本必须抓住越界锚点"
      assert_includes err, "999999", "错误信息应指出越界位置"
    end
  end

  # 反证：用 target 的（篡改后）脚本执行同一内容就检测不到。
  def test_target_scripts_would_be_bypassed
    Dir.mktmpdir do |dir|
      trusted = File.join(dir, "trusted")
      target = File.join(dir, "target")
      out_dir = File.join(dir, "out")
      [trusted, target, out_dir].each { |d| FileUtils.mkdir_p(d) }

      tar = File.join(dir, "base.tar")
      system("git", "archive", "HEAD", "-o", tar, chdir: ROOT) || skip("无法导出仓库归档")
      system("tar", "--force-local", "-xf", tar, "-C", trusted) || skip("无法解归档")
      system("tar", "--force-local", "-xf", tar, "-C", target) || skip("无法解归档")

      File.write(File.join(target, "tools/anchors_extract.rb"), <<~RUBY, encoding: "UTF-8")
        module AnchorExtractor
          def self.run(*) = 0
        end
        exit(AnchorExtractor.run(ARGV)) if $PROGRAM_NAME == __FILE__
      RUBY
      File.write(File.join(target, "docs/design/sabotage.md"),
        "# 破坏测试\n\n见 src/main.cr:999999。\n", encoding: "UTF-8")

      invocation = derive_anchors_invocation(anchors_evidence_step["run"], root: dir)
      # 同一命令，脚本改从 target 解析——这就是被绕过的场景。
      # 用相对路径还原，避免 "/tools/x.rb" 被 expand_path 当绝对路径。
      rel_script = invocation[:script].delete_prefix("#{File.expand_path(trusted)}/")
      sabotaged_script = File.join(target, rel_script)
      refute sabotaged_script.start_with?(File.expand_path(trusted))
      assert File.exist?(sabotaged_script), "反证用例需要 target 侧的脚本存在"

      _o, _e, st = Open3.capture3(
        "ruby", sabotaged_script, *materialize(invocation[:args], target:, out_dir:),
        "docs/design/sabotage.md",
        chdir: target
      )

      assert_equal 0, st.exitstatus, "对照：篡改后的脚本会放行（这正是必须用 base 的原因）"
    end
  end

  # reviewer 的判定必须覆盖「有 blocker / 有 must_fix / 无证据 unverified」三类。
  # 判定逻辑在 tools/verify_reviewer_verdict.rb（base 版本随 artifact 传递）。
  def test_reviewer_verdict_covers_three_failure_kinds
    script = File.read(File.join(ROOT, "tools/verify_reviewer_verdict.rb"), encoding: "UTF-8")
    %w[blocker must_fix unverified].each do |level|
      assert_includes script, %("#{level}"), "判定脚本应处理 #{level}"
    end
    assert_includes script, "exit(", "打回必须让进程退出码非零"
  end

  # 判定脚本的调用路径必须与 artifact 解压位置一致（CodeRabbit）：
  # 脚本落在 out/，调用写成 `ruby verify_reviewer_verdict.rb`（无前缀）
  # 会找不到文件，让 reviewer 恒失败。
  def test_reviewer_invokes_script_at_download_path
    step = reviewer_steps.find { |s| s["name"]&.include?("verdict") }
    refute_nil step, "缺少判定步骤"

    assert_includes step["run"], "out/verify_reviewer_verdict.rb",
      "脚本路径必须与 download-artifact 的 path（out）一致"
    assert_includes step["run"], "out/verification.json"

    download = reviewer_steps.find { |s| s["uses"].to_s.include?("download-artifact") }
    assert_equal "out", download.dig("with", "path"), "下载目录与调用路径必须一致"
  end

  # 发评论需要 pull-requests: write，但判定 job 必须只读（CodeRabbit）：
  # 拆分后 reviewer 只读、publish-verdict 才持写权限，且打回时仍会运行。
  def test_comment_publishing_split_from_readonly_verdict
    reviewer_perms = workflow.dig("jobs", "reviewer", "permissions") || {}
    refute_equal "write", reviewer_perms["pull-requests"],
      "reviewer 不得持写权限"

    publish = workflow.dig("jobs", "publish-verdict")
    refute_nil publish, "缺少独立的发布 job"
    assert_equal "write", publish.dig("permissions", "pull-requests"),
      "发布 job 需要 pull-requests: write"
    assert_includes publish["if"].to_s, "needs.reviewer.result == 'failure'",
      "打回时也要运行"

    runs = publish["steps"].filter_map { |s| s["run"] }.join("\n")
    refute_match(/\|\|\s*true/, runs, "不得用 || true 掩盖发布失败")
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

  def anchors_evidence_step
    step = verifier_steps.find { |s| s["name"].to_s.include?("anchors evidence") }
    refute_nil step, "缺少 anchors 证据收集步骤"
    step
  end

  def reviewer_steps
    workflow.dig("jobs", "reviewer", "steps") || []
  end

  # 把 workflow 里的相对路径参数（../target、../out/...）还原成本地临时目录路径。
  def materialize(args, target:, out_dir:)
    args.map do |arg|
      case arg
      when "../target" then target
      when %r{\A\.\./out/} then File.join(out_dir, File.basename(arg))
      else arg
      end
    end
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
