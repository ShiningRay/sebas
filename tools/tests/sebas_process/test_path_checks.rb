# frozen_string_literal: true

# 合并后 Verifier 的确定性检查：路径联动、安全不变量、CWE 汇总
# （含三轮复审补的边界用例与快照接线）。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class PathChecksTest < Minitest::Test
  include PathChecksHelpers

  # 验收 1：只改 src/ 不改 spec/ → blocker。
  def test_src_change_without_spec_blocks
    report = run_check([change("src/store/store.cr", "+def x; end\n")])
    assert report.blockers.any? { |i| i.message.include?("spec/") }
  end

  # 验收 2：workflow 用 @v4 而非 SHA → blocker。
  def test_unpinned_workflow_uses_blocks
    report = run_check([change(".github/workflows/ci.yml", "+      uses: actions/checkout@v4\n")])
    assert report.blockers.any? { |i| i.message.include?("未钉 SHA") }
  end

  # 钉了 40 位 sha 的 uses 不报。
  def test_sha_pinned_uses_passes
    sha = "a" * 40
    report = run_check([change(".github/workflows/ci.yml", "+      uses: actions/checkout@#{sha}\n")])
    assert report.blockers.empty?, report.blockers.map(&:message).inspect
  end

  # 验收 3：未 resolve 的 CWE 意见 → blocker；resolve 后不再阻断。
  def test_unresolved_cwe_blocks_and_resolved_passes
    threads = [{"isResolved" => false, "path" => "src/x.cr",
                "comments" => [{"body" => "授权绕过，见 CWE-862 与 CWE-863。"}]}]
    report = run_check([], threads: threads)
    assert report.blockers.any? { |i| i.message.include?("CWE-862") }

    resolved = threads.map { |t| t.merge("isResolved" => true) }
    report = run_check([], threads: resolved)
    assert report.blockers.empty?
  end

  # 验收 4：全合规 → 通过（无 blocker/must_fix）。
  def test_fully_compliant_change_passes
    sha = "b" * 40
    body = "行为变更已同步文档；安全边界：workflow 全部 SHA 钉版。"
    changes = [
      change("src/store/store.cr", "+def y; end\n"),
      change("spec/store/store_spec.cr", "+it \"y\" do\nend\n"),
      change("docs/design/design.md", "+## 新行为\n"),
      change(".github/workflows/ci.yml", "+      uses: actions/checkout@#{sha}\n")
    ]
    report = run_check(changes, body: body)
    assert report.pass?, report.items.map(&:message).inspect
  end

  # tools/ 有实质改动但无 test_*.rb 测试变更 → blocker。
  def test_tools_change_without_tests_blocks
    report = run_check([change("tools/new_script.rb", "+puts 1\n")])
    assert report.blockers.any? { |i| i.message.include?("test_*.rb") }
  end

  # 新的测试目录约定必须被认作测试改动：只改 tools/tests/ 下的文件即可豁免联动。
  def test_tools_tests_directory_counts_as_test_change
    report = run_check([change("tools/new_script.rb", "+puts 1\n"),
                        change("tools/tests/sebas_process/test_new_script.rb", "+assert true\n")])
    refute report.blockers.any? { |i| i.message.include?("test_*.rb") }
  end

  # 纯空白/注释改动豁免 spec 联动，且以 acceptable 留痕。
  def test_comment_only_src_change_is_exempted_with_trail
    report = run_check([change("src/store/store.cr", "+# 注释说明\n-# 旧注释\n+  \n")])
    refute report.blockers.any? { |i| i.message.include?("spec/") }
    assert report.acceptable_items.any? { |i| i.message.include?("空白/注释") }
  end

  # src 改动 + 正文声明「无行为变更」→ 文档联动豁免。
  def test_no_behavior_change_declaration_exempts_docs
    report = run_check([change("src/store/store.cr", "+def x; end\n"),
                        change("spec/store/store_spec.cr", "+it {}\n")],
      body: "本次为内部重构，无行为变更")
    refute report.must_fix_items.any? { |i| i.message.include?("docs/") }
  end

  # workflow 改动缺「安全边界」说明 → must_fix；有声明则豁免。
  def test_workflow_change_requires_security_boundary_note
    sha = "c" * 40
    report = run_check([change(".github/workflows/ci.yml", "+      uses: x/y@#{sha}\n")])
    assert report.must_fix_items.any? { |i| i.message.include?("安全边界") }

    report = run_check([change(".github/workflows/ci.yml", "+      uses: x/y@#{sha}\n")], body: "安全边界：无新增权限")
    assert report.must_fix_items.empty?
  end

  # 凭据正则：puts + token 同行 → must_fix。
  def test_credential_in_log_line_is_must_fix
    report = run_check([change("src/keys/store.cr", "+    puts token_info\n")])
    assert report.must_fix_items.any? { |i| i.message.include?("凭据") }
  end

  # 规则文件自身与测试文件不扫凭据正则（避免自触发）。
  def test_rule_and_test_files_are_not_scanned
    report = run_check([change("tools/test_path_checks.rb", "+    puts token_info\n"),
                        change("tools/tests/sebas_process/test_path_checks.rb", "+    puts token_info\n"),
                        change("tools/agents/lib/sebas_agents/path_checks.rb", "+  CREDENTIAL_LINE = /puts.*token/\n")])
    assert report.must_fix_items.empty?
  end

  # evidence.rb 触碰 SOURCES → blocker。
  def test_evidence_sources_touch_blocks
    report = run_check([change("tools/agents/lib/sebas_agents/policy/evidence.rb",
      "+      SOURCES = {\"workflow\" => ...}\n")])
    assert report.blockers.any? { |i| i.message.include?("SOURCES") }
  end

  # workflow 中的 force-push / 分支保护写入 → blocker。
  def test_force_push_and_branch_protection_block
    report = run_check([change(".github/workflows/rel.yml", "+      git push --force origin main\n")])
    assert report.blockers.any? { |i| i.message.include?("push 保护") }
    report = run_check([change(".github/workflows/rel.yml", "+      gh api repos/o/r/branches/main/protection -X PUT\n")])
    assert report.blockers.any? { |i| i.message.include?("分支保护") }
  end
end

class PathChecksRound2Test < Minitest::Test
  include PathChecksHelpers

  # jobI：patch 缺失的文件必须显式拒绝核验，不按空改动放行。
  def test_missing_patch_fails_closed
    report = run_check([change(".github/workflows/ci.yml", nil)], body: "安全边界：略")
    assert report.blockers.any? { |i| i.message.include?("无 patch 内容") }
  end

  # jobJ：注释里的假 sha 骗不过；带引号的合法引用能过。
  def test_uses_value_is_validated_whole
    report = run_check([change(".github/workflows/ci.yml",
      "+      uses: actions/checkout@v4 # uses: x/y@#{'a' * 40}\n")])
    assert report.blockers.any? { |i| i.message.include?("未钉 SHA") }, "注释中的 40 位文本不能代替字段校验"

    quoted = run_check([change(".github/workflows/ci.yml",
      "+      uses: \"actions/checkout@#{'b' * 40}\"\n")])
    assert quoted.blockers.empty?, quoted.blockers.map(&:message).inspect
  end

  # jobD：git push -f 短参数也拦；普通 push 不拦。
  def test_git_push_short_force_flag_blocks
    report = run_check([change(".github/workflows/rel.yml", "+      git push -f origin main\n")])
    assert report.blockers.any? { |i| i.message.include?("push 保护") }
    report = run_check([change(".github/workflows/rel.yml", "+      git push origin main\n")])
    assert report.blockers.empty?, report.blockers.map(&:message).inspect
  end

  # jobK：读取分支保护配置（GET）不触发；新增写方法触发。
  def test_branch_protection_read_does_not_block
    report = run_check([change(".github/workflows/rel.yml", "+      gh api repos/o/r/branches/main/protection\n")])
    assert report.blockers.empty?, "只读 GET 不应触发"
    report = run_check([change(".github/workflows/rel.yml", "+      gh api repos/o/r/branches/main/protection -X PUT\n")])
    assert report.blockers.any? { |i| i.message.include?("分支保护") }
  end

  # jobF：test_ 前缀的 Markdown 不满足 tools 测试联动。
  def test_tools_test_pattern_requires_rb
    report = run_check([change("tools/new_script.rb", "+puts 1\n"),
                        change("tools/test_notes.md", "+note\n")])
    assert report.blockers.any? { |i| i.message.include?("test_*.rb") }

    ok = run_check([change("tools/new_script.rb", "+puts 1\n"),
                    change("tools/tests/docs/test_new_script.rb", "+assert true\n")])
    refute ok.blockers.any? { |i| i.message.include?("test_*.rb") }
  end

  # jobG：纯注释 src 改动同时豁免文档联动，完整报告通过。
  def test_comment_only_src_change_exempts_docs_linkage
    report = run_check([change("src/store/store.cr", "+# 注释\n-# 旧注释\n")])
    assert report.pass?, "纯注释改动应完整通过：#{report.items.map(&:message).inspect}"
    assert report.acceptable_items.any?
  end
end

class PathChecksRound3Test < Minitest::Test
  include PathChecksHelpers

  # julr：删除未钉引用 + 新增钉版引用 = 正常修复，不得报 blocker。
  def test_deleted_unpinned_uses_does_not_block
    report = run_check([change(".github/workflows/ci.yml",
      "-      uses: actions/checkout@v4\n+      uses: actions/checkout@#{'a' * 40}\n")])
    assert report.blockers.empty?, report.blockers.map(&:message).inspect
  end

  # juln：--method 空格形式与 -X 前置都拦；不依赖路径与方法顺序；GET 不拦。
  def test_branch_protection_write_method_variants
    variants = [
      "+      gh api repos/o/r/branches/main/protection --method PUT\n",
      "+      gh api -X PUT repos/o/r/branches/main/protection\n",
      "+      gh api repos/o/r/branches/main/protection -X DELETE\n"
    ]
    variants.each do |patch|
      report = run_check([change(".github/workflows/rel.yml", patch)])
      assert report.blockers.any? { |i| i.message.include?("分支保护") }, patch
    end
    get_only = run_check([change(".github/workflows/rel.yml", "+      gh api repos/o/r/branches/main/protection\n")])
    assert get_only.blockers.empty?
  end

  # jobI 补充：patch 缺失同时不产生其他误判条目。
  def test_missing_patch_only_reports_the_missing_file
    report = run_check([change("src/new.cr", nil)])
    assert_equal 1, report.blockers.length
    assert_includes report.blockers.first.message, "src/new.cr"
  end
end

class PathChecksIntegrationTest < Minitest::Test
  include SnapshotHelpers

  def run_pre(data)
    SebasAgents::Verifier.verify_merge(
      10, 39, SebasAgents::Model::Snapshot.from_hash(data), pre: true
    )
  end

  # 与既有合并前 fixture 同构（SnapshotHelpers 原语自构）。
  def pre_data_with_pr_extra(issue_body:, pr_extra: {})
    snapshot(
      issues: [issue(39, body: issue_body)],
      pull_requests: [{
        "number" => 10, "state" => "OPEN", "closing_issues" => [39],
        "checks" => [{"name" => "spec", "status" => "COMPLETED", "conclusion" => "SUCCESS"}],
        "review_threads" => []
      }.merge(pr_extra)],
      trusted_bots: ["github-actions[bot]"],
      source_authors: {
        "https://github.com/o/r/issues/1#issuecomment-1" => "github-actions[bot]"
      },
      source_bodies: {
        "https://github.com/o/r/issues/1#issuecomment-1" => evidence(
          subject: "issue:39", merged: false, source: "workflow"
        )
      }
    )
  end

  def test_snapshot_without_files_leaves_unverified_trail
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    report = run_pre(pre_data_with_pr_extra(issue_body: body))
    assert report.pass?, "缺 files 不产生 blocker"
    assert report.unverified_items.any? { |i| i.message.include?("变更文件清单") }
  end

  def test_snapshot_with_violating_files_blocks
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    files = [{"filename" => "src/store/new.cr", "patch" => "+def x; end\n"}]
    report = run_pre(pre_data_with_pr_extra(issue_body: body, pr_extra: {"files" => files, "body" => "PR 正文"}))
    refute report.pass?
    assert report.blockers.any? { |i| i.message.include?("spec/") }
  end

  def test_snapshot_with_compliant_files_passes
    body = automation + evidence(subject: "issue:39", merged: false, source: "workflow")
    files = [{"filename" => "src/store/new.cr", "patch" => "+def x; end\n"},
             {"filename" => "spec/store/new_spec.cr", "patch" => "+it \"x\" do\nend\n"},
             {"filename" => "docs/design/design.md", "patch" => "+## x\n"}]
    report = run_pre(pre_data_with_pr_extra(
      issue_body: body,
      pr_extra: {"files" => files, "body" => "文档已同步；安全边界：无 workflow 改动"}
    ))
    assert report.pass?, "全合规应通过：#{report.items.map(&:message).inspect}"
  end
end
