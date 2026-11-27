# frozen_string_literal: true

# ci.yml 的「先 review，再跑 CI」顺序契约。
#
# ## 为什么需要这个测试
#
# 顺序完全由 needs 表达——把 `needs: [changes, await-review]` 改回 `needs: changes`
# 时，三平台矩阵照常绿，没有任何信号会提示「审查又被并行跑了」。
# 这类静默退化只能靠断言钉住：
#   1. 必检的 spec / ameba 必须等 await-review；
#   2. await-review 在非 PR 事件上必须成功（不能 skipped，否则下游矩阵跟着 skip）；
#   3. 等待上限必须小于 job 超时，否则 fail-open 永远来不及触发。

require_relative "../support/boot"
require_relative "../../await_review"

class CiWorkflowTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  WORKFLOW = File.join(ROOT, ".github", "workflows", "ci.yml")
  GATE = "await-review"

  def workflow
    @workflow ||= YAML.safe_load_file(WORKFLOW)
  end

  def jobs
    workflow["jobs"]
  end

  def text
    @text ||= File.read(WORKFLOW, encoding: "UTF-8")
  end

  def needs_of(job)
    Array(jobs.dig(job, "needs"))
  end

  # --- 顺序 ---

  def test_gate_job_exists
    assert jobs.key?(GATE), "缺 #{GATE} 门闸 job"
    assert_equal GATE, jobs.dig(GATE, "name"), "job 名要与分支保护可见的显示名一致"
  end

  # 必检项：spec×3（matrix 同一个 job）与 ameba。二者都必须排在审查之后。
  def test_required_checks_wait_for_review
    %w[spec lint].each do |job|
      assert_includes needs_of(job), GATE,
        "#{job} 必须在审查收尾后才起跑，否则矩阵会先绿、审查意见后到"
    end
  end

  # changes 与 await-review 互不依赖，可并行；await-review 若也依赖 changes
  # 就把「纯文档跳过」和「等审查」串成一条链，白白多等一轮。
  def test_gate_does_not_depend_on_changes
    assert_empty needs_of(GATE)
  end

  # docs / verify 是数秒级的确定性核验，先给反馈比排队等审查更有价值；
  # 把它们塞进等待链只会让 PR 的文档错误晚 5-10 分钟才暴露。
  def test_fast_gates_stay_parallel
    %w[docs verify].each do |job|
      refute_includes needs_of(job), GATE,
        "#{job} 是秒级核验，不应排在审查之后"
    end
  end

  # --- 非 PR 事件不得 skipped ---

  # needs 把 skipped 视为不满足：若 await-review 在 push:main 上被 job-level
  # `if` 跳过，spec 与 ameba 会跟着 skip，main 的 CI 就整体不跑了。
  def test_gate_has_no_job_level_condition
    refute jobs.dig(GATE, "if"), "门闸不能用 job-level if 跳过，否则非 PR 事件会连带 skip 下游"
  end

  # 门闸现在是真判定：脚本判出 actionable 时 job 必须变红，下游矩阵才不跑。
  # 所以等待步骤绝不能带 continue-on-error——那会把「有问题」吞成「照常跑」。
  def test_wait_step_is_not_masked
    refute_equal true, wait_step["continue-on-error"],
      "等待步骤一旦 continue-on-error，判出整改也会被吞成 success"
  end

  # 门闸会红，靠「加进必检」保证 skip 不等于放行。
  # GitHub 文档：依赖失败 job 的 job 会被 skipped 且可能不阻塞合并。
  # 因此这份契约必须与分支保护同步，docs 是它的记录处。
  def test_gate_is_documented_as_required_check
    # 必检 contexts 留在 development-workflow.md §4，门闸细节搬到了 pr-gate.md。
    doc = File.read(File.join(ROOT, "docs/design/process/development-workflow.md"), encoding: "UTF-8")
    gate_doc = File.read(File.join(ROOT, "docs/design/process/pr-gate.md"), encoding: "UTF-8")

    assert_includes doc, GATE,
      "必检 contexts 里必须记录 #{GATE}，否则门闸变红时下游 skip 会被当成放行"
    assert_includes gate_doc, "必检",
      "pr-gate.md 要说明「门闸自身必须是必检」这条前提"
  end

  # 门闸要贴整改清单评论，必须有 PR 写权限；其余仍是只读。
  def test_gate_can_write_pr_comments
    perms = jobs.dig(GATE, "permissions") || {}
    assert_equal "write", perms["pull-requests"], "贴整改清单评论需要 PR 写权限"
    assert_equal "read", perms["contents"], "门闸不需要写代码"
    assert_equal "read", perms["checks"], "门闸只需读 check run"
  end

  def test_gate_short_circuits_on_non_pull_request
    steps = jobs.dig(GATE, "steps")
    short_circuit = steps.find { |s| s["name"].to_s.include?("Not a pull request") }
    refute_nil short_circuit, "缺非 PR 事件的短路步骤"
    assert_includes short_circuit["if"], "github.event_name != 'pull_request'"

    wait = steps.find { |s| s["run"].to_s.include?("tools/await_review.rb") }
    refute_nil wait, "门闸必须真的调用 tools/await_review.rb"
    assert_includes wait["if"], "github.event_name == 'pull_request'"
  end

  # --- fail-open 不被超时压死 ---

  # 脚本的等待上限（默认 900s）必须显著小于 job 超时，否则 GitHub 先杀掉 job，
  # fail-open 分支永远走不到，「放行」变成「硬失败」。
  def test_job_timeout_exceeds_script_wait
    job_minutes = jobs.dig(GATE, "timeout-minutes")
    refute_nil job_minutes, "门闸必须显式声明超时"
    script_seconds = AwaitReview::DEFAULT_TIMEOUT_SECONDS
    margin = job_minutes * 60 - script_seconds

    assert_operator margin, :>=, 120,
      "job 超时 #{job_minutes}min 与脚本等待 #{script_seconds}s 至少留 2 分钟余量"
  end

  # 等待步骤自己也要有超时：脚本仅在两次轮询之间查 deadline，拦不住一次
  # 挂住的 gh 调用（gh 无默认请求超时）。步骤超时 + continue-on-error 才能
  # 保证「脚本挂死」也不会把下游带成 skipped。
  def test_wait_step_has_its_own_timeout
    step = wait_step
    refute_nil step["timeout-minutes"], "等待步骤必须声明 timeout-minutes"
    # 超时被杀时 job 会红（这是新语义：门闸没判定完就不该放行下游）。
    refute_equal true, step["continue-on-error"], "超时不能被吞成 success"

    # 步骤超时要大于脚本等待，否则脚本自己的 fail-open 永远来不及触发。
    assert_operator step["timeout-minutes"] * 60, :>, AwaitReview::DEFAULT_TIMEOUT_SECONDS
    assert_operator step["timeout-minutes"], :<, jobs.dig(GATE, "timeout-minutes"),
      "步骤超时必须小于 job 超时，才能在 job 被杀前先落地"
  end

  def wait_step
    step = jobs.dig(GATE, "steps").find { |s| s["run"].to_s.include?("tools/await_review.rb") }
    refute_nil step, "门闸必须真的调用 tools/await_review.rb"
    step
  end

  def test_step_passes_head_sha_not_merge_sha
    wait = jobs.dig(GATE, "steps").find { |s| s["run"].to_s.include?("tools/await_review.rb") }
    env = wait["env"] || {}

    # 审查方在 PR head sha 上跑 check run；用 merge commit sha 查不到结果，
    # 门闸就永远等超时——虽然 fail-open 不会卡死，但顺序等于没做。
    assert_equal "${{ github.event.pull_request.head.sha }}", env["HEAD_SHA"]
    assert_equal "${{ github.event.pull_request.number }}", env["PR_NUMBER"]
    assert_equal "${{ github.repository }}", env["REPO"]
  end

  # --- 权限与钉版 ---

  def test_gate_permissions_are_minimal
    perms = jobs.dig(GATE, "permissions")
    # 写权限仅限贴评论；代码与 check run 都是只读。
    assert_equal "read", perms["contents"]
    assert_equal "read", perms["checks"]
    assert_equal "write", perms["pull-requests"]
    assert_equal %w[checks contents issues pull-requests].sort, perms.keys.sort,
      "门闸不该申请多余权限"
  end

  def test_top_level_permissions_stay_read_only
    assert_equal({"contents" => "read"}, workflow["permissions"])
  end

  # 复用 verify.yml 的口径：任何非本地 action 都必须 SHA 钉版。
  def test_all_actions_are_sha_pinned
    unpinned = []
    collect(jobs, unpinned)
    assert_empty unpinned, "所有 action 必须 SHA 钉版：#{unpinned.inspect}"
  end

  def collect(node, acc)
    case node
    when Hash
      node.each do |key, value|
        if key == "uses" && value.is_a?(String) && !value.start_with?("./")
          acc << value unless value.match?(/@[0-9a-f]{40}\z/)
        else
          collect(value, acc)
        end
      end
    when Array
      node.each { |item| collect(item, acc) }
    end
  end

  # --- 触发器仍覆盖三平台门禁 ---

  def test_triggers_unchanged
    triggers = workflow["on"] || workflow[true]
    assert_equal ["main"], triggers.dig("push", "branches")
    assert_equal ["main"], triggers.dig("pull_request", "branches")
    assert triggers.key?("workflow_dispatch")
  end

  # 并发组必须按事件分流（#221）：PR 侧继续取消前一轮，main 侧不得取消。
  #
  # PR 侧：门闸最长等 15 分钟，同一 PR 的新推送若不取消旧轮，队列会堆积大量空等。
  # main 侧：Evidence 升级只认 CI 结论 success；若下一次 push 顶掉正在跑的 main CI，
  # 那一轮的 Evidence 停在 merged_into_main=false，后继卡永久 blocked。
  # 这两个方向互为反例，任何一边退化都不会让本测试以外的东西报错——所以两条都钉住。
  def test_concurrency_cancels_superseded_runs
    concurrency = workflow["concurrency"]
    assert_match(/github\.event_name/, concurrency["group"].to_s,
      "并发组必须按事件分流，否则 push:main 与 pull_request 共用一组")
    assert_includes concurrency["group"], "github.ref"

    cancel = concurrency["cancel-in-progress"]
    assert_match(/github\.event_name\s*==\s*'pull_request'/, cancel.to_s,
      "取消必须限定在 pull_request 事件上，main 侧要跑完以升级 Evidence")
  end

  # 「等出现」的宽限必须小于主等待上限，否则它不会先触发，
  # 「不在审查范围」的快速放行就退化成干等满 15 分钟。
  def test_appear_window_is_shorter_than_main_wait
    appear = AwaitReview::DEFAULT_APPEAR_SECONDS
    assert_operator appear, :<, AwaitReview::DEFAULT_TIMEOUT_SECONDS
    # 实测最慢一次 check run 出现用了 113s，宽限必须留足。
    assert_operator appear, :>=, 300
  end

  def test_comment_explains_the_ordering
    assert_includes text, "先 review", "workflow 里要写清顺序意图，避免后人当噪音删掉"
  end
end
