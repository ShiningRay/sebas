# frozen_string_literal: true

# CLI triage：研判动作、待决问题渲染、Proposal 专用判定与拒绝路径。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class CliTriageTest < Minitest::Test
  include SnapshotHelpers
  include CliHelpers

  def test_triage_with_verdict_produces_actions
    data = snapshot(issues: [issue(7, body: "bug 描述", labels: [])])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      verdict = File.join(dir, "v.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      File.write(verdict, JSON.generate({"decision" => "bug-confirmed", "body" => "复现步骤"}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "7", "--snapshot", snap, "--verdict", verdict])
      assert_equal 0, status
      payload = JSON.parse(out)
      assert_equal "bug-confirmed", payload["decision"]
      assert(payload["actions"].any? { |action| action["name"] == "bug" })
    end
  end

  def test_triage_without_verdict_asks_model
    data = snapshot(issues: [issue(7, body: "bug 描述")])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "7", "--snapshot", snap])
      assert_equal 1, status
      assert_equal "needs-model-verdict", JSON.parse(out)["decision"]
    end
  end

  def test_triage_proposal_needs_design_does_not_assign_or_schedule
    data = snapshot(issues: [issue(8, labels: ["proposal", "needs-triage"])])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      verdict = File.join(dir, "v.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      File.write(verdict, JSON.generate({"decision" => "needs-design", "body" => "待确认兼容性"}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 0, status
      actions = JSON.parse(out)["actions"]
      assert(actions.any? { |action| action["action"] == "add_label" && action["name"] == "proposal:needs-design" })
      assert(actions.any? { |action| action["action"] == "set_type" && action["type"] == "Proposal" })
      refute(actions.any? { |action| %w[add_assignee suggest_milestone close].include?(action["action"]) })
    end
  end

# 存量卡迁移期：type=Proposal 但标签已清，仍须走 Proposal 流程。
def test_proposal_detected_by_type_without_label
  data = snapshot(issues: [issue(8, labels: ["needs-triage"], type: "Proposal")])
  Dir.mktmpdir do |dir|
    snap = File.join(dir, "s.json")
    verdict = File.join(dir, "v.json")
    File.write(snap, JSON.generate(data), encoding: "UTF-8")
    File.write(verdict, JSON.generate({"decision" => "needs-design", "body" => "待确认"}), encoding: "UTF-8")
    status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
    assert_equal 0, status
    assert_includes out, "proposal:needs-design"
  end
end

# Proposal 不能走 accepted：那条路径会加 enhancement 并指派，语义不对。
def test_accepted_rejects_proposal_type
  data = snapshot(issues: [issue(8, labels: ["proposal"], type: "Proposal")])
  Dir.mktmpdir do |dir|
    snap = File.join(dir, "s.json")
    verdict = File.join(dir, "v.json")
    File.write(snap, JSON.generate(data), encoding: "UTF-8")
    File.write(verdict, JSON.generate({"decision" => "accepted"}), encoding: "UTF-8")
    status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
    assert_equal 1, status
    assert_includes out, "accepted-design"
  end
end

# 已是 Proposal 的卡不再重复写 type（避免无谓 API 调用）。
def test_proposal_plan_skips_redundant_set_type
  data = snapshot(issues: [issue(8, labels: ["proposal"], type: "Proposal")])
  Dir.mktmpdir do |dir|
    snap = File.join(dir, "s.json")
    verdict = File.join(dir, "v.json")
    File.write(snap, JSON.generate(data), encoding: "UTF-8")
    File.write(verdict, JSON.generate({"decision" => "needs-design", "body" => "待确认"}), encoding: "UTF-8")
    status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
    assert_equal 0, status
    actions = JSON.parse(out)["actions"]
    refute(actions.any? { |action| action["action"] == "set_type" })
  end
end

# 选卡排除不能只认标签：type=Proposal 的卡即使带 work_package 块也不得进候选。
def test_selection_excludes_type_proposal_without_label
  data = snapshot(issues: [
    issue(1, labels: [], type: "Proposal", body: automation(order: [4, 1])),
    issue(2, labels: [], body: automation(order: [4, 2]))
  ])
  action = select(data)
  assert_equal "claim_issue", action.action
  assert_equal 2, action.issue
  assert(action.excluded.any? { |item| item["issue"] == 1 && item["reason"].include?("proposal") })
end

  def proposal_verdict(data, dir, decision: "accepted-design", url: nil)
    url ||= "https://github.com/o/r/issues/8#issuecomment-123"
    match = SebasAgents::Triager::DECISION_URL.match(url)
    parent = if match[:kind] == "pull"
      "https://api.github.com/repos/o/r/pulls/#{match[:number]}"
    else
      "https://api.github.com/repos/o/r/issues/#{match[:number]}"
    end
    data["proposal_evidence"] ||= {}
    data["proposal_evidence"][url] = {
      "author" => "ShiningRay",
      "body" => "<!-- proposal-verdict: #{decision} -->\n理由：符合设计边界。",
      "parent" => parent
    }
    snap = File.join(dir, "s.json")
    verdict = File.join(dir, "v.json")
    File.write(snap, JSON.generate(data), encoding: "UTF-8")
    File.write(verdict, JSON.generate({
      "decision" => decision,
      "body" => "Maintainer 已裁决；排期另议。",
      "maintainer_decision_url" => url
    }), encoding: "UTF-8")
    [snap, verdict, url]
  end

# 反馈给 Maintainer 的问题要在评论里渲染成可勾选清单（GitHub 渲染 issue 评论支持任务列表）。
def test_triage_renders_checkbox_options_for_maintainer_questions
  verdict = {
    "decision" => "needs-design",
    "body" => "有两处取舍要定。",
    "questions" => [
      {"q" => "租约凭据放哪", "why" => "影响跨机器与安全边界。",
       "options" => ["正文块", "协调评论", "仅本地记录与标签"], "recommend" => 2}
    ]
  }
  issue = SebasAgents::Model::Issue.from_hash(
    {"number" => 190, "title" => "x", "state" => "OPEN", "body" => "", "labels" => ["proposal"]}
  )
  comment = SebasAgents::Triager.comment_for("needs-design", verdict)
  assert_includes comment, "### 待决问题（请勾选）"
  assert_includes comment, "- [ ] **A** 正文块"
  assert_includes comment, "- [ ] **B** 协调评论"
  assert_includes comment, "- [ ] **C** 仅本地记录与标签（推荐）"
  # 勾选只改评论、工具读不到，这一点必须写明，否则会以为勾了就生效。
  assert_includes comment, "勾选只改这条评论，工具读不到"
end

# 没有 questions 时不应凭空多出一个小节。
def test_triage_omits_questions_section_when_absent
  issue = SebasAgents::Model::Issue.from_hash(
    {"number" => 1, "title" => "x", "state" => "OPEN", "body" => "", "labels" => []}
  )
  comment = SebasAgents::Triager.comment_for("needs-info", {"body" => "缺复现步骤"})
  refute_includes comment, "待决问题"
  assert_includes comment, "缺复现步骤"
end

def triage_comment(verdict)
  issue = SebasAgents::Model::Issue.from_hash(
    {"number" => 2, "title" => "x", "state" => "OPEN", "body" => "", "labels" => ["proposal"]}
  )
  SebasAgents::Triager.comment_for(verdict["decision"], verdict)
end

# recommend 越界、负数、非整数（含字符串数字与浮点）都不得渲染推荐标记。
def test_triage_ignores_invalid_recommend_index
  [5, -1, "1", 1.0, true].each do |bad|
    verdict = {
      "decision" => "needs-design", "body" => "x",
      "questions" => [{"q" => "选哪个", "options" => ["甲", "乙"], "recommend" => bad}]
    }
    comment = triage_comment(verdict)
    refute_includes comment, "（推荐）", "recommend=#{bad.inspect} 不应产生推荐标记"
  end
end

# 过滤空项后编号按显示顺序重排，recommend 仍绑定原始选项。
def test_triage_keeps_recommend_bound_to_original_option
  verdict = {
    "decision" => "needs-design", "body" => "x",
    "questions" => [{"q" => "选哪个", "options" => ["", "甲", "乙"], "recommend" => 1}]
  }
  comment = triage_comment(verdict)
  assert_includes comment, "- [ ] **A** 甲（推荐）"
  assert_includes comment, "- [ ] **B** 乙"
end

# recommend 指向被过滤掉的空项：不得把推荐转嫁给别的选项。
def test_triage_does_not_migrate_recommend_from_empty_option
  verdict = {
    "decision" => "needs-design", "body" => "x",
    "questions" => [{"q" => "选哪个", "options" => ["", "甲", "乙"], "recommend" => 0}]
  }
  comment = triage_comment(verdict)
  refute_includes comment, "（推荐）"
  assert_includes comment, "- [ ] **A** 甲"
end

# 空问题列表不产出小节；选项为空时给出「待补充选项」而不是静默省略。
def test_triage_question_edge_cases
  refute_includes triage_comment({"decision" => "needs-design", "body" => "x", "questions" => []}), "待决问题"
  refute_includes triage_comment({"decision" => "needs-design", "body" => "x"}), "待决问题"
  empty_options = triage_comment({"decision" => "needs-design", "body" => "x",
    "questions" => [{"q" => "待定项", "options" => []}]})
  assert_includes empty_options, "待补充选项"
end

# 结构非法必须拒绝执行，不能静默丢弃待决问题——丢了调用方看不出。
def test_triage_rejects_malformed_questions
  [
    {"decision" => "needs-design", "body" => "x", "questions" => {"q" => "x"}},
    {"decision" => "needs-design", "body" => "x", "questions" => [false]},
    {"decision" => "needs-design", "body" => "x", "questions" => [{"q" => ""}]},
    {"decision" => "needs-design", "body" => "x", "questions" => [{"q" => "x", "options" => "甲乙"}]}
  ].each do |verdict|
    error = assert_raises(SebasAgents::InvalidPlan) { triage_comment(verdict) }
    assert_includes error.message, "questions"
  end
end

  def test_triage_proposal_acceptance_requires_maintainer_evidence
    data = snapshot(issues: [issue(8, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      verdict = File.join(dir, "v.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      File.write(verdict, JSON.generate({"decision" => "accepted-design", "body" => "接受"}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "maintainer_decision_url"
    end
  end

  def test_triage_proposal_acceptance_clears_states_without_assigning
    data = snapshot(issues: [issue(8, labels: ["proposal", "proposal:needs-design"])])
    Dir.mktmpdir do |dir|
      snap, verdict, url = proposal_verdict(data, dir)
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 0, status
      payload = JSON.parse(out)
      actions = payload["actions"]
      assert(actions.any? { |action| action["action"] == "add_label" && action["name"] == "proposal:accepted-design" })
      assert(actions.any? { |action| action["action"] == "remove_label" && action["name"] == "proposal:needs-design" })
      assert_includes payload["comment"], url
      assert_includes payload["comment_preview"], url
      refute(actions.any? { |action| %w[add_assignee suggest_milestone close].include?(action["action"]) })
    end
  end

  def test_triage_proposal_decisions_require_proposal_label
    data = snapshot(issues: [issue(7, labels: ["enhancement"])])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      verdict = File.join(dir, "v.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      File.write(verdict, JSON.generate({"decision" => "needs-design"}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "7", "--snapshot", snap, "--verdict", verdict])
      assert_equal 2, status
      assert_includes out, "proposal 标签"
    end
  end

  def test_triage_proposal_decline_records_reason_and_closes
    data = snapshot(issues: [issue(8, labels: ["proposal", "proposal:accepted-design"])])
    Dir.mktmpdir do |dir|
      snap, verdict, = proposal_verdict(data, dir, decision: "declined")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 0, status
      actions = JSON.parse(out)["actions"]
      assert(actions.any? { |action| action["action"] == "add_label" && action["name"] == "proposal:declined" })
      assert(actions.any? { |action| action["action"] == "close" && action["reason"] == "not planned" })
      assert(actions.any? { |action| action["action"] == "remove_label" && action["name"] == "proposal:accepted-design" })
      refute(actions.any? { |action| %w[add_assignee suggest_milestone].include?(action["action"]) })
    end
  end

  def test_triage_proposal_superseded_requires_successor
        # 继任者必须真实存在且带 proposal 标签，否则校验会拒绝。
    data = snapshot(issues: [
      issue(8, labels: ["proposal", "proposal:accepted-design"]),
      issue(9, labels: ["proposal"])
    ])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      verdict = File.join(dir, "v.json")
      File.write(verdict, JSON.generate({"decision" => "superseded", "body" => "方向被替换"}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "superseded_by"
    end
  end

  def test_triage_proposal_superseded_closes_and_links_successor
    # 继任者必须真实存在且带 proposal 标签，否则校验会拒绝。
    data = snapshot(issues: [
      issue(8, labels: ["proposal", "proposal:accepted-design"]),
      issue(9, labels: ["proposal"])
    ])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      verdict = File.join(dir, "v.json")
      File.write(verdict, JSON.generate({"decision" => "superseded", "body" => "方向被替换", "superseded_by" => 9}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 0, status
      payload = JSON.parse(out)
      actions = payload["actions"]
      assert(actions.any? { |action| action["action"] == "add_label" && action["name"] == "proposal:superseded" })
      assert(actions.any? { |action| action["action"] == "close" && action["reason"] == "not planned" })
      assert_includes payload["comment"], "继任 Proposal：#9"
    end
  end

  def test_triage_proposal_superseded_rejects_self_reference
    data = snapshot(issues: [issue(8, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      verdict = File.join(dir, "v.json")
      File.write(verdict, JSON.generate({"decision" => "superseded", "superseded_by" => 8}), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "自身"
    end
  end

  def test_triage_proposal_rejects_untrusted_or_unbound_verdicts
    data = snapshot(issues: [issue(8, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      [
        ["https://github.com/other/r/issues/8#issuecomment-123", "当前仓库"],
        ["https://github.com/o/r/issues/9#issuecomment-123", "当前 Proposal"]
      ].each do |url, message|
        snap, verdict, = proposal_verdict(data, dir, url: url)
        status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
        assert_equal 1, status
        assert_includes out, message
      end

      snap, verdict, url = proposal_verdict(data, dir)
      data["proposal_evidence"][url]["author"] = "external-user"
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "Maintainer"

      data["proposal_evidence"][url]["author"] = "ShiningRay"
      data["proposal_evidence"][url].delete("body")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "裁决正文"
    end
  end

  def test_triage_proposal_rejects_cross_repo_short_backlink
    url = "https://github.com/o/r/pull/9#discussion_r123"
    data = snapshot(issues: [issue(8, labels: ["proposal"])], pull_requests: [{"number" => 9, "body" => "Design other/r#8"}])
    Dir.mktmpdir do |dir|
      snap, verdict, = proposal_verdict(data, dir, url: url)
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "回链"
    end
  end

  def test_triage_proposal_design_pr_verdict_requires_backlink
    url = "https://github.com/o/r/pull/9#discussion_r123"
    data = snapshot(issues: [issue(8, labels: ["proposal"])], pull_requests: [{"number" => 9, "body" => ""}])
    Dir.mktmpdir do |dir|
      snap, verdict, = proposal_verdict(data, dir, url: url)
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "回链"

      data["pull_requests"][0]["body"] = "Design: https://github.com/o/r/issues/8"
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 0, status, out

      data["pull_requests"][0]["body"] = "Design: https://github.com/other/r/issues/8"
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "回链"
    end
  end

  def test_triage_proposal_decline_requires_nonempty_reason
    data = snapshot(issues: [issue(8, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      snap, verdict, url = proposal_verdict(data, dir, decision: "declined")
      data["proposal_evidence"][url]["body"] = "<!-- proposal-verdict: declined -->"
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
      assert_equal 1, status
      assert_includes out, "理由"
    end
  end

  def test_triage_proposal_rejects_assignment_and_scheduling_decisions
    data = snapshot(issues: [issue(8, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      %w[accepted bug-confirmed rejected fixed by-design].each do |decision|
        snap = File.join(dir, "s.json")
        verdict = File.join(dir, "v.json")
        File.write(snap, JSON.generate(data), encoding: "UTF-8")
        File.write(verdict, JSON.generate({"decision" => decision}), encoding: "UTF-8")
        status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
        assert_equal 1, status
        assert_includes out, "Proposal 只允许"
      end
    end
  end

  def test_triage_proposal_preserves_clarification_duplicate_and_escalation
    data = snapshot(issues: [issue(8, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      {"needs-info" => "question", "duplicate" => "close", "escalate" => "notify_maintainer"}.each do |decision, expected|
        snap = File.join(dir, "s.json")
        verdict = File.join(dir, "v.json")
        File.write(snap, JSON.generate(data), encoding: "UTF-8")
        File.write(verdict, JSON.generate({"decision" => decision, "body" => "说明"}), encoding: "UTF-8")
        _status, out, = run_cli(["triage", "8", "--snapshot", snap, "--verdict", verdict])
        actions = JSON.parse(out)["actions"]
        assert(actions.any? { |action| action["action"] == expected || action["name"] == expected })
        refute(actions.any? { |action| %w[add_assignee suggest_milestone].include?(action["action"]) })
      end
    end
  end

# Proposal 带合法 work_package Automation 块也不得进入 Implementer 选卡：
# 与 in_progress_issues 同口径，否则提案会被当作工作认领。
def test_selection_excludes_proposal_even_with_valid_automation
  block = "```json automation\n" \
    "{\"schema\":1,\"kind\":\"work_package\",\"order\":[4,1],\"depends_on\":[],\"external\":[]}\n```\n"
  data = snapshot(issues: [issue(8, body: block, labels: ["proposal"])])
  action = select(data)
  refute_equal "claim_issue", action.action
  assert(action.excluded.any? { |row| row["reason"].to_s.include?("proposal") }, action.excluded.inspect)
end

  # 有 Automation 块但结构残缺时不能短路成工作包：会按坏元数据写 type/assignee。
  # 也不能静默降级为普通研判——必须显式拒绝。
  def test_triage_rejects_malformed_automation_block
    data = snapshot(issues: [issue(7, body: "```json automation\n{\"kind\":\"work_package\"}\n```\n")])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "7", "--snapshot", snap])
      assert_equal 1, status
      assert_includes out, "invalid_plan"
    end
  end

  # Proposal 即使带 Automation 块也走专用判定，不得被工作包短路抢走。
  def test_triage_proposal_with_automation_block_still_uses_proposal_rules
    block = "```json automation\n" \
      "{\"schema\":1,\"kind\":\"work_package\",\"order\":[1],\"depends_on\":[],\"external\":[]}\n```\n"
    data = snapshot(issues: [issue(8, body: block, labels: ["proposal"])])
    Dir.mktmpdir do |dir|
      snap = File.join(dir, "s.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      status, out, = run_cli(["triage", "8", "--snapshot", snap])
      assert_equal 1, status
      assert_equal "needs-model-verdict", JSON.parse(out)["decision"]
    end
  end
end

class ClosedIssueLabelTest < Minitest::Test
  include SnapshotHelpers

  def test_closed_issue_with_stale_label_is_not_active_claim
    data = snapshot(issues: [
      issue(1, body: automation, status: "In progress", state: "CLOSED", state_reason: "COMPLETED"),
      issue(2, body: automation(order: [4, 2]))
    ])
    assert_equal "claim_issue", select(data).action
  end
end
