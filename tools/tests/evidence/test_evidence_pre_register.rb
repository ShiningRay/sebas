# frozen_string_literal: true

# 两阶段登记（#126）：合并前写 merged_into_main=false 的块，
# 并锁住 CI 读数口径（只有 advisory / 只有自身 check / 未知状态）。

require_relative "../support/boot"
require_relative "../../evidence_register"

class EvidencePreRegisterTest < Minitest::Test
  ER = EvidenceRegister

  class FakeGh
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def call(path, method:, body: nil)
      @calls << [method, path]
      key = "#{method} #{path}"
      value = @responses.respond_to?(:call) ? @responses.call(key, @calls) : @responses[key]
      raise "gh api #{method} #{path} 失败" if value.nil? && method != "DELETE"

      value
    end
  end

  PRE_ENV = {
    "GITHUB_REPOSITORY" => "o/r",
    "EVENT_NAME" => "workflow_run",
    "RUN_PR" => "99",
    "RUN_URL" => ""
  }.freeze

  PRE_PR = {
    "merged_at" => nil, "state" => "open", "body" => "Fixes #42",
    "base" => {"ref" => "main"}, "head" => {"sha" => "head123"},
    "html_url" => "https://github.com/o/r/pull/99"
  }.freeze

  def green_checks
    {"check_runs" => [
      {"name" => "spec", "status" => "completed", "conclusion" => "success"},
      {"name" => "ameba", "status" => "completed", "conclusion" => "success"}
    ]}
  end

  def run_pre(fake)
    ER.runner = fake
    ER.git_runner = ->(*_args) { raise "合并前不应查 git 祖先" }
    out = StringIO.new
    code = ER.run(env: PRE_ENV, out: out)
    [code, fake.calls, out.string]
  ensure
    ER.runner = nil
    ER.git_runner = nil
  end

  def pre_fake(overrides = {})
    FakeGh.new({
      "GET repos/o/r/pulls/99" => PRE_PR,
      "GET repos/o/r/issues/42" => {"state" => "open", "body" => "## 目标\nx\n"},
      "GET repos/o/r/commits/head123/check-runs?per_page=100" => green_checks,
      "POST repos/o/r/issues/42/comments" => {"id" => 7, "html_url" => "https://gh/c/7"},
      "PATCH repos/o/r/issues/comments/7" => {},
      "PATCH repos/o/r/issues/42" => {}
    }.merge(overrides))
  end

  # 核心：合并前登记必须写 merged_into_main=false，否则等于伪造合并证据。
  def test_pre_register_writes_not_merged_block
    written = nil
    fake = FakeGh.new(lambda do |key, _calls|
      case key
      when "GET repos/o/r/pulls/99" then PRE_PR
      when "GET repos/o/r/issues/42" then {"state" => "open", "body" => "## 目标\nx\n"}
      when "GET repos/o/r/commits/head123/check-runs?per_page=100" then green_checks
      when "POST repos/o/r/issues/42/comments" then {"id" => 7, "html_url" => "https://github.com/o/r/issues/42#issuecomment-7"}
      when "PATCH repos/o/r/issues/comments/7" then {}
      when "PATCH repos/o/r/issues/42" then {}
      else raise "unexpected #{key}"
      end
    end)
    # 拦截 PATCH body：直接调用底层 register 无法拿到 body，改用 runner 记录。
    original_call = fake.method(:call)
    captured = nil
    fake.define_singleton_method(:call) do |path, method: "GET", body: nil|
      captured = body if method == "PATCH" && path.end_with?("/comments/7")
      original_call.call(path, method: method, body: body)
    end

    ER.runner = fake
    ER.git_runner = ->(*_a) { raise "合并前不应查 git" }
    out = StringIO.new
    code = ER.run(env: PRE_ENV, out: out)
    ER.runner = nil
    ER.git_runner = nil

    assert_equal 0, code, out.string
    refute_nil captured, "必须发出评论 PATCH"
    written = ER.parse_block(captured["body"].to_s)
    refute_nil written
    assert_equal false, written["merged_into_main"], "合并前登记不得声称已合并"
    assert_nil written["merge_commit"]
    assert_equal "issue:42", written["subject"]
  ensure
    ER.runner = nil
    ER.git_runner = nil
  end

  def test_pre_register_block_has_false_and_nil_commit
    b = ER.evidence_block(issue_number: 1, pr_number: 2, merge_commit: nil,
      checks: "c", untested: [], source_ref: "r", merged_into_main: false)
    assert_equal false, b["merged_into_main"]
    assert_nil b["merge_commit"]
  end

  def test_pre_register_rejects_already_merged_pr
    # 已合并的 PR 不走合并前路径：应由合并后登记处理，且不得写 false 块。
    fake = FakeGh.new(
      "GET repos/o/r/pulls/99" => PRE_PR.merge("merged_at" => "2026-01-01T00:00:00Z",
        "merge_commit_sha" => "abc", "body" => "no linkage")
    )
    code, calls, out = run_pre(fake)
    assert_equal 0, code
    assert(calls.none? { |m, _| m == "POST" }, "不得写评论，calls=#{calls.inspect}")
    assert(out.include?("未通过 Fixes #n") || out.include?("不在 main 上"),
      "已合并 PR 应走合并后路径，out=#{out}")
  end

  def test_pre_register_blocks_when_checks_empty
    # 空 checks 不能当「全绿」：那是把「没看见」当「通过」。
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {"check_runs" => []})
    code, calls, out = run_pre(fake)
    assert_equal 1, code
    assert_includes out, "没有任何 CI 检查记录"
    assert(calls.none? { |m, _| m == "POST" }, "不得登记，calls=#{calls.inspect}")
  end

  def test_pre_register_blocks_on_failing_check
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {
      "check_runs" => [{"name" => "spec", "status" => "completed", "conclusion" => "failure"}]
    })
    code, _calls, out = run_pre(fake)
    assert_equal 1, code
    assert_includes out, "失败的检查"
  end

  def test_pre_register_blocks_on_pending_check
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {
      "check_runs" => [{"name" => "spec", "status" => "in_progress", "conclusion" => nil}]
    })
    code, _calls, out = run_pre(fake)
    assert_equal 1, code
    assert_includes out, "未完成的检查"
  end

  # 本 workflow 自身的 check 必须排除（#126 实测）：register evidence 运行时
  # 是 in_progress、失败时是 failure，不排除会自我阻塞且永远无法通过。
  def test_pre_register_ignores_own_check_run
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {
      "check_runs" => [
        {"name" => "spec", "status" => "completed", "conclusion" => "success"},
        {"name" => "register evidence", "status" => "in_progress", "conclusion" => nil}
      ]
    })
    code, calls, out = run_pre(fake)
    assert_equal 0, code, "自身 check 不应阻塞，out=#{out}"
    assert_includes calls, ["POST", "repos/o/r/issues/42/comments"]
  end

  def test_pre_register_ignores_own_failed_check_run
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {
      "check_runs" => [
        {"name" => "spec", "status" => "completed", "conclusion" => "success"},
        {"name" => "register evidence", "status" => "completed", "conclusion" => "failure"}
      ]
    })
    code, _calls, out = run_pre(fake)
    assert_equal 0, code, "上一次预登记的失败不应成为新阻塞，out=#{out}"
  end

  # 排除自身后若没有任何其它检查，仍须拒绝——不能把「只看见自己」当全绿。
  def test_pre_register_blocks_when_only_own_check_present
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {
      "check_runs" => [{"name" => "register evidence", "status" => "completed", "conclusion" => "success"}]
    })
    code, _calls, out = run_pre(fake)
    assert_equal 1, code
    assert_includes out, "没有任何 CI 检查记录"
  end

  # 第三方审阅进行中不得阻塞预登记：CodeRabbit 一轮 4-8 分钟，
  # 而它不在分支保护的必需检查里，等它只会让预登记反复失败（PR #237 实测 5 次）。
  def test_pre_register_ignores_pending_advisory_check
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {
      "check_runs" => [
        {"name" => "spec", "status" => "completed", "conclusion" => "success"},
        {"name" => "ameba", "status" => "completed", "conclusion" => "success"},
        {"name" => "CodeRabbit", "status" => "in_progress", "conclusion" => nil}
      ]
    })
    code, calls, out = run_pre(fake)
    assert_equal 0, code, "advisory pending 不应阻塞，out=#{out}"
    assert_includes calls, ["POST", "repos/o/r/issues/42/comments"]
  end

  # advisory 已完成但结论不是成功（服务故障 CANCELLED）时必须拒绝登记：
  # 这类情况要人工裁决，不能静默放过。
  def test_pre_register_still_blocks_on_failed_advisory_check
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {
      "check_runs" => [
        {"name" => "spec", "status" => "completed", "conclusion" => "success"},
        {"name" => "CodeRabbit", "status" => "completed", "conclusion" => "cancelled"}
      ]
    })
    code, _calls, out = run_pre(fake)
    assert_equal 1, code, "advisory 失败结论仍须阻塞，out=#{out}"
    assert_includes out, "第三方审阅检查失败"
  end

  # 只剩一条「已完成的 CodeRabbit success」也必须拒绝：
  # 它是 advisory，成功不代表门禁 CI 跑过。
  def test_pre_register_blocks_when_only_completed_advisory_present
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {
      "check_runs" => [
        {"name" => "CodeRabbit", "status" => "completed", "conclusion" => "success"}
      ]
    })
    code, calls, out = run_pre(fake)
    assert_equal 1, code
    assert_includes out, "除第三方审阅外没有任何 CI 检查记录"
    assert(calls.none? { |m, _| m == "POST" }, "不得登记，calls=#{calls.inspect}")
  end

  # 排除自身与 advisory 后若没有门禁类检查，仍须拒绝——不能把「第三方审阅进行中」
  # 当作 CI 已确认。
  def test_pre_register_blocks_when_only_advisory_checks_present
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {
      "check_runs" => [
        {"name" => "register evidence", "status" => "completed", "conclusion" => "success"},
        {"name" => "CodeRabbit", "status" => "in_progress", "conclusion" => nil}
      ]
    })
    code, calls, out = run_pre(fake)
    assert_equal 1, code
    assert_includes out, "除第三方审阅外没有任何 CI 检查记录"
    assert(calls.none? { |m, _| m == "POST" }, "不得登记，calls=#{calls.inspect}")
  end

  # advisory 整类被排除出 gate_runs 后，未知状态会落不进任何判定分支。
  # 必须在豁免前显式拒绝——GitHub 只定义 queued/in_progress/completed 三态。
  def test_pre_register_blocks_on_unknown_advisory_status
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {
      "check_runs" => [
        {"name" => "spec", "status" => "completed", "conclusion" => "success"},
        {"name" => "CodeRabbit", "status" => "bogus", "conclusion" => nil}
      ]
    })
    code, calls, out = run_pre(fake)
    assert_equal 1, code, "未知状态必须拒绝，out=#{out}"
    assert_includes out, "状态未知的检查记录"
    assert(calls.none? { |m, _| m == "POST" }, "不得登记，calls=#{calls.inspect}")
  end

  # 未知状态对非 advisory 检查同样拒绝：与 advisory 一致，不留静默放行口。
  def test_pre_register_blocks_on_unknown_gate_status
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {
      "check_runs" => [
        {"name" => "spec", "status" => "weird", "conclusion" => "success"}
      ]
    })
    code, _calls, out = run_pre(fake)
    assert_equal 1, code
    assert_includes out, "状态未知的检查记录"
  end

  # 两份 advisory 名单分别给 workflow 脚本与 agents 库使用，必须一致：
  # 只改一处会让 selector 与 Evidence 预登记对同一个 check 判出相反结论。
  def test_advisory_lists_stay_in_sync
    require_relative "../../evidence_register_twophase"
    require_relative "../../agents/lib/sebas_agents"
    assert_equal SebasAgents::AdvisoryChecks::NAMES,
      EvidenceRegister::TwoPhase::ADVISORY_CHECK_NAMES
  end

  # 缺 status 的记录不能被名称过滤静默跳过（CodeRabbit）：先校验元数据、再排除自身。
  def test_pre_register_blocks_on_metadata_incomplete_own_check
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {
      "check_runs" => [
        {"name" => "spec", "status" => "completed", "conclusion" => "success"},
        {"name" => "register evidence"}
      ]
    })
    code, calls, out = run_pre(fake)
    assert_equal 1, code, "缺 status 必须拒绝，out=#{out}"
    assert_includes out, "元数据不完整"
    assert(calls.none? { |m, _| m == "POST" }, "不得写入，calls=#{calls.inspect}")
  end

  def test_pre_register_blocks_on_metadata_incomplete_other_check
    fake = pre_fake("GET repos/o/r/commits/head123/check-runs?per_page=100" => {
      "check_runs" => [
        {"name" => "spec", "status" => "completed", "conclusion" => "success"},
        {"name" => "another", "conclusion" => "success"}
      ]
    })
    code, calls, out = run_pre(fake)
    assert_equal 1, code
    assert_includes out, "元数据不完整"
    assert(calls.none? { |m, _| m == "POST" })
  end

  def test_pre_register_skips_when_issue_closed
    fake = pre_fake("GET repos/o/r/issues/42" => {"state" => "closed", "state_reason" => "completed", "body" => ""})
    code, calls, out = run_pre(fake)
    assert_equal 0, code
    assert_includes out, "不是 open"
    assert(calls.none? { |m, _| m == "POST" })
  end

  # 已存在 false 块 → 幂等跳过，不重复发评论。
  def test_pre_register_is_idempotent_on_false_block
    b = ER.evidence_block(issue_number: 42, pr_number: 99, merge_commit: nil,
      checks: "c", untested: [], source_ref: "https://gh/c/1", merged_into_main: false)
    fake = pre_fake("GET repos/o/r/issues/42" => {
      "state" => "open", "body" => "## 目标\nx\n\n```json evidence\n#{JSON.generate(b)}\n```\n"
    })
    code, calls, out = run_pre(fake)
    assert_equal 0, code
    assert_includes out, "已有合并前 Evidence"
    assert(calls.none? { |m, _| m == "POST" }, "幂等不得发评论，calls=#{calls.inspect}")
  end

  # 未合并却声称已合并 → 篡改，必须 fail-closed。
  # 注意：该块经过 existing_evidence 判为 :valid，因此 pre_register 必须自己再查 merged 标志。
  # 判定信息走 warn（stderr），不是 out；这里断言退出码即可。
  def test_pre_register_rejects_block_claiming_merged
    b = ER.evidence_block(issue_number: 42, pr_number: 99, merge_commit: "abc",
      checks: "c", untested: [], source_ref: "https://gh/c/1", merged_into_main: true)
    fake = pre_fake("GET repos/o/r/issues/42" => {
      "state" => "open", "body" => "```json evidence\n#{JSON.generate(b)}\n```\n"
    })
    _out = nil
    code = nil
    captured = StringIO.new
    _orig = $stderr
    $stderr = captured
    begin
      code, calls, _out = run_pre(fake)
    ensure
      $stderr = _orig
    end
    assert_equal 1, code, "未合并却声称已合并必须 fail-closed，stderr=#{captured.string}"
    assert_includes captured.string, "声称 merged_into_main=true"
    assert(calls.none? { |m, _| m == "POST" })
  end
end
