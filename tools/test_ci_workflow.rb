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
#
# 注意：本测试与 workflow 同在 PR 可改范围内，是回归绊线而非 PR 时控制；
# 阻止 PR 自行放宽的独立控制是 .github/ 审核红线（见 AGENTS.md 安全红线）。

require "minitest/autorun"
require "yaml"
require_relative "await_review"

class CiWorkflowTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
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

  # 门闸崩了绝不能让 job 变红：GitHub 文档明确写着「依赖失败 job 的 job 会被
  # skipped 且可能不阻塞合并」。若门闸红，spec/ameba 被 skip，PR 反而能在没有
  # spec 的情况下合入。所以每个可能失败的步骤都必须 continue-on-error。
  def test_gate_steps_never_fail_the_job
    jobs.dig(GATE, "steps").each do |step|
      next unless step["uses"] || step["run"]
      # 非 PR 短路步骤只是一句 echo，不可能失败，不必加 continue-on-error。
      next if step["name"].to_s.include?("Not a pull request")

      assert_equal true, step["continue-on-error"],
        "步骤 #{step["name"].inspect} 失败会让下游必检被 skip，进而可能不阻塞合并"
    end
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
    assert_equal({"contents" => "read", "checks" => "read"}, jobs.dig(GATE, "permissions"),
      "门闸只读代码与 check run，不需要写权限")
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

  # 并发组必须仍在 PR ref 上取消前一轮：门闸最长等 15 分钟，
  # 若同一 PR 的新推送不能取消旧轮，队列会堆积大量空等。
  def test_concurrency_cancels_superseded_runs
    assert_equal true, workflow.dig("concurrency", "cancel-in-progress")
    assert_includes workflow.dig("concurrency", "group"), "github.ref"
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
