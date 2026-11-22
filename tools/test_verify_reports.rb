# frozen_string_literal: true

# verify_merge_reports / verify_final_verdict 单测（#122；#124 改名 final-verdict）。
#
# 重点覆盖 CodeRabbit 在 PR #129 报的 CWE-636：工具异常被吞掉后放行。
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "verify_merge_reports"
require_relative "verify_final_verdict"

class VerifyMergeReportsTest < Minitest::Test
  VMR = VerifyMergeReports

  def with_out
    Dir.mktmpdir { |dir| yield dir }
  end

  def write_out(dir, name, content)
    File.write(File.join(dir, name), content, encoding: "UTF-8")
  end

  # 「报告缺失」检查会在缺具体报告时记 blocker——那是正确行为，
  # 但多数用例只想测单侧逻辑，所以默认给两侧都放最小合法产物。
  def base_evidence(dir)
    write_out(dir, "anchors_extract.txt", "已写入 anchors.json：0 条锚点\nextract exit=0\n")
    write_out(dir, "anchors_report.json", JSON.generate({"items" => []}))
    write_out(dir, "docs_report_1.json", JSON.generate({"items" => []}))
    write_out(dir, "docs_failures.txt", "")
  end

  # anchors 侧置为「生成成功且产出报告」，docs 侧留空——由调用方补。
  def base_docs_evidence(dir)
    write_out(dir, "anchors_report.json", JSON.generate({"items" => []}))
  end

  def report_file(dir, name, items)
    write_out(dir, name, JSON.generate({"items" => items}))
  end

  # --- 正常路径 ---

  def test_collects_reports_from_both_sources
    with_out do |dir|
      base_evidence(dir)
      report_file(dir, "anchors_report.json", [
        {"id" => "must_fix-1", "level" => "must_fix", "message" => "锚点不符", "evidence" => nil}
      ])
      report_file(dir, "docs_report_1.json", [
        {"id" => "acceptable-1", "level" => "acceptable", "message" => "存档锚", "evidence" => nil}
      ])

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 1, report["counts"]["must_fix"]
      assert_equal 1, report["counts"]["acceptable"]
      assert_equal "打回", VMR.conclusion(report["counts"])
    end
  end

  def test_collects_multiple_docs_batches
    with_out do |dir|
      base_evidence(dir)
      report_file(dir, "docs_report_1.json", [])
      report_file(dir, "docs_report_2.json", [
        {"id" => "blocker-1", "level" => "blocker", "message" => "超 400 行", "evidence" => nil}
      ])

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 1, report["counts"]["blocker"]
    end
  end

  # --- CWE-636：工具异常不得被当成通过 ---

  def test_tool_error_response_becomes_blocker
    with_out do |dir|
      base_evidence(dir)
      # CLI 的错误响应：有 error 无 items
      write_out(dir, "docs_report_1.json",
        JSON.generate({"ok" => false, "error" => {"code" => "usage_error", "message" => "参数超过上限"}}))
      # 覆盖 helper 写的空 docs_failures，确保 docs 侧只有这一条错误响应
      File.delete(File.join(dir, "docs_failures.txt"))

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 1, report["counts"]["blocker"], "错误响应必须转 blocker"
      assert_includes report["items"].first["message"], "结构非法"
    end
  end

  def test_invalid_json_report_becomes_blocker
    with_out do |dir|
      base_evidence(dir)
      write_out(dir, "docs_report_1.json", "{not json")

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 1, report["counts"]["blocker"]
      assert_includes report["items"].first["message"], "不是合法 JSON"
    end
  end

  def test_empty_report_file_becomes_blocker
    with_out do |dir|
      base_evidence(dir)
      write_out(dir, "docs_report_1.json", "   \n")

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 1, report["counts"]["blocker"]
      assert_includes report["items"].first["message"], "为空文件"
    end
  end

  def test_unknown_level_becomes_blocker
    with_out do |dir|
      base_evidence(dir)
      report_file(dir, "docs_report_1.json", [
        {"id" => "x-1", "level" => "wtf", "message" => "未知级别", "evidence" => nil}
      ])

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 1, report["counts"]["blocker"]
      assert_includes report["items"].first["message"], "未知 level"
    end
  end

  # 生成器非零退出但没输出 ERROR 行 → 工具异常，必须 blocker。
  def test_extract_nonzero_without_error_lines_becomes_blocker
    with_out do |dir|
      base_evidence(dir)
      write_out(dir, "anchors_extract.txt", "已写入 anchors.json：0 条锚点\nextract exit=1\n")

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 1, report["counts"]["blocker"]
      assert_includes report["items"].first["message"], "工具异常"
    end
  end

  def test_extract_nonzero_with_error_lines_uses_them
    with_out do |dir|
      base_evidence(dir)
      write_out(dir, "anchors_extract.txt",
        "ERROR docs/a.md 引用 src/x.cr:999999，但该文件只有 3 行\n共 1 处行号越界，拒绝生成 anchors\nextract exit=1\n")

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 1, report["counts"]["blocker"]
      assert_includes report["items"].first["message"], "999999"
    end
  end

  # 核验非零但报告无阻断项 → 报告结构异常，必须 blocker。
  def test_verify_nonzero_without_blockers_becomes_blocker
    with_out do |dir|
      base_evidence(dir)
      report_file(dir, "anchors_report.json", [])
      write_out(dir, "anchors_extract.txt", "anchors verify exit=1\n")

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 1, report["counts"]["blocker"]
      assert_includes report["items"].first["message"], "报告结构异常"
    end
  end

  # 生成器退出 0 但未产出清单：verify anchors 被静默跳过 → 必须 blocker。
  def test_successful_extract_without_manifest_becomes_blocker
    with_out do |dir|
      base_evidence(dir)
      write_out(dir, "anchors_extract.txt",
        "已写入 anchors.json：0 条锚点\nextract exit=0\ngenerator exit=0 但未产出 anchors.json（工具异常）\n")

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 1, report["counts"]["blocker"]
      assert_includes report["items"].first["message"], "未产出 anchors.json"
    end
  end

  # 生成器成功退出却无报告：核验被静默跳过 → blocker。
  # docs 侧保持齐全，确保红的是 anchors 侧（CodeRabbit：此前的夹具反而
  # 是 docs 缺失，删掉 anchors 检查也不会红）。
  def test_successful_extract_without_anchors_report_becomes_blocker
    with_out do |dir|
      base_evidence(dir)
      File.delete(File.join(dir, "anchors_report.json"))
      write_out(dir, "anchors_extract.txt", "已写入 anchors.json：0 条锚点\nextract exit=0\n")

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 1, report["counts"]["blocker"]
      assert_includes report["items"].first["message"], "anchors_report.json"
    end
  end

  # docs 侧没有任何批次报告、也没有失败记录 → blocker。
  def test_missing_docs_reports_become_blocker
    with_out do |dir|
      base_evidence(dir)
      File.delete(File.join(dir, "docs_report_1.json"))
      write_out(dir, "docs_failures.txt", "")

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 1, report["counts"]["blocker"]
      assert_includes report["items"].first["message"], "核验被跳过"
    end
  end

  # 非 Hash 条目（`{"items":[null]}`）不能静默跳过 → blocker。
  def test_non_hash_item_becomes_blocker
    with_out do |dir|
      base_evidence(dir)
      write_out(dir, "docs_report_1.json", JSON.generate({"items" => [nil, "str", {"id" => "ok-1", "level" => "acceptable", "message" => "好", "evidence" => nil}]}))

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 2, report["counts"]["blocker"], "null 与字符串各记一条"
      assert_equal 1, report["counts"]["acceptable"], "合法条目仍被保留"
    end
  end

  # anchors 核验异常退出时，docs 侧的同级条目不能把它掩盖掉
  # （CodeRabbit：原判断扫全局 items）。
  def test_anchors_verify_failure_not_masked_by_docs_must_fix
    with_out do |dir|
      base_evidence(dir)
      # docs 侧有 must_fix，anchors 报告为空但核验非零退出
      File.write(File.join(dir, "docs_report_1.json"), JSON.generate({"items" => [
        {"id" => "d1", "level" => "must_fix", "message" => "应修", "evidence" => nil}
      ]}))
      write_out(dir, "anchors_report.json", JSON.generate({"items" => []}))
      write_out(dir, "anchors_extract.txt", "已写入 anchors.json：1 条锚点\nextract exit=0\nanchors verify exit=1\n")

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_includes report["items"].map { |i| i["message"] }.join("\n"), "核验非零退出"
    end
  end

  # 对照：anchors 报告内已有 blocker 时，非零退出是预期行为，不重复记账。
  def test_anchors_verify_failure_with_blocker_in_report_not_duplicated
    with_out do |dir|
      base_evidence(dir)
      write_out(dir, "anchors_report.json", JSON.generate({"items" => [
        {"id" => "a1", "level" => "blocker", "message" => "越界", "evidence" => nil}
      ]}))
      write_out(dir, "anchors_extract.txt", "extract exit=0\nanchors verify exit=1\n")

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 1, report["counts"]["blocker"]
    end
  end

  def test_docs_failures_become_blockers
    with_out do |dir|
      base_evidence(dir)
      report_file(dir, "docs_report_1.json", [])
      write_out(dir, "docs_failures.txt", "第 2 批 verify docs 执行失败\n结构非法：缺 items 数组\n")

      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 2, report["counts"]["blocker"]
    end
  end

  # 证据完全缺失不能静默通过。
  def test_missing_all_evidence_becomes_blocker
    with_out do |dir|
      report = VMR.run(dir, base_sha: "b", head_sha: "h")
      assert_equal 2, report["counts"]["blocker"], "anchors 与 docs 两侧的缺失都要记"
      assert_equal "打回", VMR.conclusion(report["counts"])
    end
  end

  def test_observed_carries_shas
    with_out do |dir|
      base_evidence(dir)
      report_file(dir, "anchors_report.json", [])
      report_file(dir, "docs_report_1.json", [])
      report = VMR.run(dir, base_sha: "base111", head_sha: "head222")
      assert_equal "base111", report["observed"]["base"]
      assert_equal "head222", report["observed"]["head"]
    end
  end

  # --- 结论口径 ---

  def test_conclusion_levels
    assert_equal "打回", VMR.conclusion({"blocker" => 1, "must_fix" => 0, "unverified" => 0})
    assert_equal "打回", VMR.conclusion({"blocker" => 0, "must_fix" => 1, "unverified" => 0})
    assert_equal "有条件通过", VMR.conclusion({"blocker" => 0, "must_fix" => 0, "unverified" => 2})
    assert_equal "通过", VMR.conclusion({"blocker" => 0, "must_fix" => 0, "unverified" => 0})
  end
end

class VerifyFinalVerdictTest < Minitest::Test
  VRV = VerifyFinalVerdict

  def decide(items)
    VRV.decide({"items" => items})
  end

  def test_passes_when_only_acceptable
    result = decide([{"level" => "acceptable", "message" => "存档锚", "evidence" => nil}])
    assert result["passed"]
    assert_includes VRV.render(result).join("\n"), "**通过**"
  end

  def test_blocks_on_blocker
    result = decide([{"level" => "blocker", "message" => "越界", "evidence" => nil}])
    refute result["passed"]
    assert_includes VRV.render(result).join("\n"), "打回"
  end

  def test_blocks_on_must_fix
    result = decide([{"level" => "must_fix", "message" => "应修", "evidence" => nil}])
    refute result["passed"]
  end

  # 无间接证据的未实测项：与 Reviewer.final_verification 同口径，打回。
  def test_blocks_on_unverified_without_evidence
    result = decide([{"level" => "unverified", "message" => "没测", "evidence" => nil}])
    refute result["passed"]
  end

  # 有间接证据的未实测项：属「有条件通过」，不阻断 PR。
  def test_passes_on_unverified_with_evidence
    result = decide([{"level" => "unverified", "message" => "没测", "evidence" => "https://example.org/run"}])
    assert result["passed"], "有间接证据时不阻断"
  end

  def test_empty_items_pass
    assert decide([])["passed"]
  end

  # 消费边界的结构校验（CodeRabbit）：损坏报告不得显示为「终验通过」。
  def test_missing_items_key_fails
    result = VRV.decide({})
    refute result["passed"], "缺 items 必须打回"
    assert result["structure_problem"]
    assert_includes VRV.render(result).join("\n"), "报告结构非法"
  end

  def test_non_hash_report_fails
    refute VRV.decide(nil)["passed"]
    refute VRV.decide("str")["passed"]
    refute VRV.decide([1, 2])["passed"]
  end

  def test_non_hash_item_fails
    refute decide([nil])["passed"], "items 含 null 必须打回"
    refute decide(["str"])["passed"], "items 含字符串必须打回"
  end

  def test_unknown_level_fails
    result = decide([{"level" => "whatever", "message" => "x", "evidence" => nil}])
    refute result["passed"]
    assert_includes result["structure_problem"], "level"
  end

  # 对照：合法空报告仍通过，与上面的非法情形区分。
  def test_valid_empty_report_still_passes
    assert VRV.decide({"items" => []})["passed"]
    assert decide([{"level" => "acceptable", "message" => "存档", "evidence" => nil}])["passed"]
  end

  def test_render_lists_each_failure_kind
    result = decide([
      {"level" => "blocker", "message" => "阻断项", "evidence" => nil},
      {"level" => "must_fix", "message" => "应修项", "evidence" => nil},
      {"level" => "unverified", "message" => "无证据项", "evidence" => nil}
    ])
    text = VRV.render(result).join("\n")
    assert_includes text, "阻断：阻断项"
    assert_includes text, "应修：应修项"
    assert_includes text, "未实测且无间接证据：无证据项"
  end
end
