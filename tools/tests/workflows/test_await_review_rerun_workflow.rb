# frozen_string_literal: true

# `await-review-rerun.yml` 的契约：review 写入晚于 check run 完成时，
# 门闸必须能被重新触发，否则整改项会被静默吞掉。
#
# 这类退化和 ci.yml 的顺序契约同型：把 workflow 删掉或把触发事件改回只管 push，
# 其余测试全绿、PR 照常合并，没有任何信号。
#
# 安全边界也在测试里：事件里的 review 作者若不是基线审查方，job 必须不做事——
# 否则任何人都能伪造一条 `Actionable comments posted: 99` 反复烧 runner。

require_relative "../support/boot"

class AwaitReviewRerunWorkflowTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  WORKFLOW = File.join(ROOT, ".github", "workflows", "await-review-rerun.yml")

  def workflow
    @workflow ||= YAML.safe_load_file(WORKFLOW)
  end

  def text
    @text ||= File.read(WORKFLOW, encoding: "UTF-8")
  end

  def triggers
    # YAML 1.1 把裸 `on` 解析成布尔 true，两种键都要认。
    Array((workflow["on"] || workflow[true]).keys)
  end

  # 只监听 pull_request_review 的 submitted：edited / dismissed 不该触发重判
  # （前者是改正文，后者说明意见已被撤回，不需要跑 CI）。
  def test_triggers_on_review_submitted_only
    assert_includes triggers, "pull_request_review"
    assert_equal ["submitted"], Array((workflow["on"] || workflow[true])["pull_request_review"]["types"])
  end

  # 事件类型不对，要么产生海量无效 run（pull_request 会在每次 push 上重复
  # 触发重跑），要么根本赶不上 review 写入。
  def test_does_not_duplicate_the_pr_triggers
    %w[pull_request push workflow_dispatch].each do |event|
      refute_includes triggers, event, "重判 workflow 不应监听 #{event}，那是 ci.yml 的职责"
    end
  end

  # 作者必须是基线审查方：否则任何人都能伪造 actionable 文案反复烧 runner。
  def test_author_is_pinned_to_the_review_bot
    job = workflow.dig("jobs", "rerun")
    refute_nil job, "缺 rerun job"
    assert_includes job["if"].to_s, "github.event.review.user.login == 'coderabbitai[bot]'"
  end

  # 取首个匹配，与 tools/await_review.rb 的 ACTIONABLE_PATTERN 同口径。
  # review 正文可能引用示例文本（本仓库文档与测试就含该文案），取最大值会把
  # 示例当结论。这条断言钉住 grep 的 -m1 与后续数字抽取。
  def test_first_actionable_marker_wins
    assert_includes text, "grep -oEm1 'Actionable comments posted:", "必须只取首个匹配"
    refute_includes text, "sort -n", "取最大值会把正文里的示例当结论"
    refute_includes text, "tail -1", "取最大值会把正文里的示例当结论"
  end

  # 查询失败与找不到 run 都必须降级为 warning 并以 0 退出：`set -e` 下让赋值
  # 命令非零退会直接终止步骤，补漏 job 变红就淹没了真正的门闸结论。
  def test_query_failures_degrade_to_warning
    assert_includes text, '|| true)"', "head sha 读取必须兜住失败"
    assert_includes text, "if ! run_id=", "run 查询失败必须走独立 warning 分支"
    assert_includes text, "查询 $sha 的 CI run 失败", "查询失败要有明确 warning"
  end

  def test_closed_pull_requests_are_skipped
    assert_includes workflow.dig("jobs", "rerun", "if").to_s, "pull_request.state == 'open'"
  end

  # N=0 或没有该文案时不重跑：无整改项本来就不该多烧一轮。
  def test_zero_actionable_does_not_rerun
    assert_includes text, "count=0", "无 actionable 文案时必须短路"
    step = workflow.dig("jobs", "rerun", "steps").find { |s| s["name"].to_s.include?("Rerun") }
    refute_nil step
    refute_equal "always()", step["if"].to_s
    assert_includes step["if"].to_s, "count != '0'", "重跑步骤必须受 actionable 计数约束"
  end

  # 重跑必须落在同一个 head 上：换 sha 重跑没有意义（门闸读的是该 sha 的 review）。
  def test_rerun_is_bound_to_the_head_sha
    assert_includes text, "head_sha=$sha", "必须按 head sha 查 run"
    assert_includes text, "/rerun", "必须调用 rerun 接口"
  end

  # 重跑失败只警告不失败：补漏动作不该掩盖门闸本身的结论。
  def test_rerun_failure_is_a_warning
    assert_includes text, "::warning::重跑 CI run", "重跑失败要降级为 warning"
    refute_match(/set -euo pipefail\n.*\n.*gh api -X POST .*\/rerun"\s*$/, text,
      "rerun 失败不能因 pipefail 让 job 红")
  end

  # 不 checkout、不执行 PR 内文件：本 workflow 只用 gh api 读事件与重跑。
  def test_does_not_checkout_pr_content
    refute_includes text, "actions/checkout",
      "重判 workflow 不需要 checkout；引入它等于给 PR 内容一个执行面"
  end

  # 挂在 ci 命名空间之外的分组：否则会和主 CI 抢同一个 concurrency 槽位。
  def test_concurrency_is_separate_from_main_ci
    group = workflow["concurrency"]["group"].to_s
    assert_includes group, "await-review-rerun"
    refute_equal "ci-${{ github.ref }}", group
  end
end
