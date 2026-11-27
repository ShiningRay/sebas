# frozen_string_literal: true

# Evidence 登记主流程的失败与回滚：半截状态清理、幂等跳过、untested 冻结对账、
# 合并后升级为终态块。

require_relative "../support/boot"
require_relative "../../evidence_register"

class EvidenceRunTest < Minitest::Test
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

  BASE_ENV = {
    "GITHUB_REPOSITORY" => "o/r",
    "EVENT_NAME" => "workflow_run",
    "RUN_PR" => "99",
    "RUN_URL" => "https://ci/1"
  }.freeze

  BASE_RESPONSES = {
    "GET repos/o/r/pulls/99" => {
      "merged_at" => "x", "body" => "Fixes #42", "merge_commit_sha" => "abc",
      "base" => {"ref" => "main"}
    },
    "GET repos/o/r/issues/42" => {"state" => "closed", "state_reason" => "completed", "body" => ""}
  }.freeze

  def run_with(fake, env, git_ok: true)
    ER.runner = fake
    ER.git_runner = ->(*_args) { git_ok }
    out = StringIO.new
    code = ER.run(env: env, out: out)
    [code, fake.calls, out.string]
  ensure
    ER.runner = nil
    ER.git_runner = nil
  end

  def test_rollback_deletes_comment_when_body_not_yet_written
    fake = FakeGh.new(BASE_RESPONSES.merge(
      "POST repos/o/r/issues/42/comments" => {"id" => 1, "html_url" => "u"},
      "PATCH repos/o/r/issues/comments/1" => {},
      "GET repos/o/r/issues/42" => {"state" => "closed", "state_reason" => "completed", "body" => ""}
      # PATCH issues/42 故意缺失 → 失败
    ))
    code, calls, = run_with(fake, BASE_ENV)

    assert_equal 1, code
    assert_includes calls, ["DELETE", "repos/o/r/issues/comments/1"],
      "正文未引用时必须删除评论，calls=#{calls.inspect}"
  end

  def test_no_delete_when_body_already_references_comment
    # 模拟 PATCH 报错但服务端已写入：正文已含该 URL，不能删评论。
    fake = FakeGh.new(
      "GET repos/o/r/pulls/99" => BASE_RESPONSES["GET repos/o/r/pulls/99"],
      "GET repos/o/r/issues/42" => {
        "state" => "closed", "state_reason" => "completed",
        "body" => "see https://github.com/o/r/issues/42#issuecomment-1"
      },
      "POST repos/o/r/issues/42/comments" => {"id" => 1, "html_url" => "https://github.com/o/r/issues/42#issuecomment-1"},
      "PATCH repos/o/r/issues/comments/1" => {}
      # PATCH issues/42 缺失 → 触发回滚路径
    )
    code, calls, = run_with(fake, BASE_ENV)

    assert_equal 1, code
    refute_includes calls, ["DELETE", "repos/o/r/issues/comments/1"],
      "正文已引用评论时不得删除，calls=#{calls.inspect}"
  end

  def test_skips_when_merge_commit_not_in_main
    fake = FakeGh.new("GET repos/o/r/pulls/99" => BASE_RESPONSES["GET repos/o/r/pulls/99"])
    code, calls, out = run_with(fake, BASE_ENV, git_ok: false)

    assert_equal 0, code
    assert_equal [["GET", "repos/o/r/pulls/99"]], calls, "不得产生写入"
    assert_includes out, "不在 main 上"
  end

  # 未合并的 PR 现在走合并前登记路径（#126）：不再静默跳过，
  # 而是先核对 open / main / issue open，条件不满足才跳过。
  def test_no_writes_when_pr_not_merged_and_not_open
    # 未合并路径会先查 issue 判断是否 Proposal，故补 issue 响应（非 proposal）。
    fake = FakeGh.new(
      "GET repos/o/r/pulls/99" => {"merged_at" => nil, "state" => "closed", "body" => "Fixes #42"},
      "GET repos/o/r/issues/42" => {"labels" => []}
    )
    code, calls, out = run_with(fake, BASE_ENV)

    assert_equal 0, code
    assert_equal [["GET", "repos/o/r/pulls/99"], ["GET", "repos/o/r/issues/42"]], calls,
      "非 open 时不得写入，calls=#{calls.inspect}"
    assert_includes out, "不是 open"
  end

  def test_no_writes_when_pre_register_target_not_main
    fake = FakeGh.new(
      "GET repos/o/r/pulls/99" => {
        "merged_at" => nil, "state" => "open", "body" => "Fixes #42",
        "base" => {"ref" => "release/0.2"}
      },
      "GET repos/o/r/issues/42" => {"labels" => []}
    )
    code, calls, out = run_with(fake, BASE_ENV)

    assert_equal 0, code
    assert_equal [["GET", "repos/o/r/pulls/99"], ["GET", "repos/o/r/issues/42"]], calls
    assert_includes out, "目标分支不是 main"
  end

  def test_idempotent_skip_does_not_write
    fake = FakeGh.new(BASE_RESPONSES.merge(
      "GET repos/o/r/issues/42" => {
        "state" => "closed", "state_reason" => "completed",
        "body" => "```json evidence\n#{JSON.generate(ER.evidence_block(
          issue_number: 42, pr_number: 99, merge_commit: "abc",
          checks: "c", untested: [], source_ref: "r"
        ))}\n```"
      }
    ))
    code, calls, out = run_with(fake, BASE_ENV)

    assert_equal 0, code
    assert(calls.none? { |m, _| m != "GET" }, "幂等跳过不得产生写入，calls=#{calls.inspect}")
    assert_includes out, "已有有效 Evidence"
  end

  def test_invalid_existing_evidence_exits_nonzero
    fake = FakeGh.new(BASE_RESPONSES.merge(
      "GET repos/o/r/issues/42" => {
        "state" => "closed", "state_reason" => "completed",
        "body" => "```json evidence\n{\"subject\":\"issue:42\"}\n```"
      }
    ))
    code, calls, = run_with(fake, BASE_ENV)

    assert_equal 1, code, "结构非法的既有证据必须 fail-closed"
    assert(calls.none? { |m, _| m != "GET" })
  end

  def test_malformed_existing_block_exits_nonzero_without_writes
    fake = FakeGh.new(BASE_RESPONSES.merge(
      "GET repos/o/r/issues/42" => {
        "state" => "closed", "state_reason" => "completed",
        "body" => "```json evidence\n{not json}\n```"
      }
    ))
    code, calls, = run_with(fake, BASE_ENV)

    assert_equal 1, code, "损坏的块不能被当成缺失而追加第二份"
    assert(calls.none? { |m, _| m != "GET" }, "不得写入，calls=#{calls.inspect}")
  end

  # 首读到写入之间「未实测」小节被改动时，登记会漏掉新增项，必须中止。
  def test_aborts_when_untested_declarations_change_mid_flight
    issue_reads = 0
    fake = FakeGh.new(lambda do |key, _calls|
      case key
      when "GET repos/o/r/pulls/99" then BASE_RESPONSES["GET repos/o/r/pulls/99"]
      when "GET repos/o/r/issues/42"
        issue_reads += 1
        # 两次读取都带「未实测」小节，但内容不同——这才是真正的「期间被改」。
        body = if issue_reads == 1
          "## 目标\nx\n\n## 未实测\n\n- 原有的要求\n"
        else
          "## 目标\nx\n\n## 未实测\n\n- 原有的要求\n- 期间新增的要求\n"
        end
        {"state" => "closed", "state_reason" => "completed", "body" => body}
      when "POST repos/o/r/issues/42/comments" then {"id" => 1, "html_url" => "https://gh/c/1"}
      when "PATCH repos/o/r/issues/comments/1" then {}
      end
    end)

    code, calls, = run_with(fake, BASE_ENV)
    assert_equal 1, code, "声明变化必须中止登记"
    # 未写入正文：PATCH issues/42 不应出现。
    refute(calls.any? { |m, p| m == "PATCH" && p.end_with?("/issues/42") },
      "不得写入正文，calls=#{calls.inspect}")
  end

  def test_does_not_abort_when_declarations_unchanged
    fake = FakeGh.new(BASE_RESPONSES.merge(
      "GET repos/o/r/issues/42" => {
        "state" => "closed", "state_reason" => "completed",
        "body" => "## 目标\nx\n\n## 未实测\n\n- 稳定的要求\n"
      },
      "POST repos/o/r/issues/42/comments" => {"id" => 1, "html_url" => "https://gh/c/1"},
      "PATCH repos/o/r/issues/comments/1" => {},
      "PATCH repos/o/r/issues/42" => {}
    ))
    code, = run_with(fake, BASE_ENV)
    assert_equal 0, code, "声明未变时应正常登记"
  end

  def pre_block_body(merged: false, commit: nil, untested: [])
    b = ER.evidence_block(issue_number: 42, pr_number: 99, merge_commit: commit,
      checks: "https://gh/c/9", untested: untested,
      source_ref: "https://github.com/o/r/issues/42#issuecomment-7",
      merged_into_main: merged)
    "## 目标\nx\n\n## Evidence\n\n```json evidence\n#{JSON.generate(b)}\n```\n"
  end

  def test_after_merge_upgrades_pre_block
    registered = ER.evidence_block(issue_number: 42, pr_number: 99, merge_commit: nil,
      checks: "https://gh/c/9", untested: ["真机验证"],
      source_ref: "https://github.com/o/r/issues/42#issuecomment-7", merged_into_main: false)
    fake = FakeGh.new(
      "GET repos/o/r/pulls/99" => BASE_RESPONSES["GET repos/o/r/pulls/99"],
      "GET repos/o/r/issues/42" => {
        "state" => "closed", "state_reason" => "completed",
        "body" => pre_block_body(merged: false, commit: nil, untested: ["真机验证"])
      },
      "GET repos/o/r/issues/comments/7" => {
        "id" => 7, "user" => {"login" => "github-actions[bot]"},
        "issue_url" => "https://api.github.com/repos/o/r/issues/42",
        "body" => "```json evidence\n#{JSON.generate(registered)}\n```\n"
      },
      "PATCH repos/o/r/issues/comments/7" => {},
      "PATCH repos/o/r/issues/42" => {}
    )
    code, calls, out = run_with(fake, BASE_ENV)

    assert_equal 0, code, out
    assert_includes out, "已升级为合并后"
    assert_includes calls, ["PATCH", "repos/o/r/issues/comments/7"], "先改评论，calls=#{calls.inspect}"
    assert_includes calls, ["PATCH", "repos/o/r/issues/42"], "再改正文"
  end

  # 升级必须保留登记期冻结的 untested，不能重新从卡面读取。
  # CodeRabbit（Minor）：旧版断言 `captured = body` 是原输入字符串，测不到实际写出内容。
  # 这里直接捕获评论与正文两处 PATCH body，分别解析后断言。
  def test_after_merge_preserves_frozen_untested
    # 正文副本被篡改成空数组，登记评论仍是 ["冻结项"]。
    # 升级必须以登记评论为准，不能采信正文。
    body = pre_block_body(merged: false, commit: nil, untested: [])
    registered = ER.evidence_block(issue_number: 42, pr_number: 99, merge_commit: nil,
      checks: "https://gh/c/9", untested: ["冻结项"],
      source_ref: "https://github.com/o/r/issues/42#issuecomment-7", merged_into_main: false)

    written = {}
    fake = FakeGh.new(lambda do |key, _calls|
      case key
      when "GET repos/o/r/pulls/99" then BASE_RESPONSES["GET repos/o/r/pulls/99"]
      when "GET repos/o/r/issues/42" then {"state" => "closed", "state_reason" => "completed", "body" => body}
      when "GET repos/o/r/issues/comments/7"
        {
          "id" => 7, "user" => {"login" => "github-actions[bot]"},
          "issue_url" => "https://api.github.com/repos/o/r/issues/42",
          "body" => "```json evidence\n#{JSON.generate(registered)}\n```\n"
        }
      when "PATCH repos/o/r/issues/comments/7" then {}
      when "PATCH repos/o/r/issues/42" then {}
      else raise "unexpected #{key}"
      end
    end)
    original = fake.method(:call)
    fake.define_singleton_method(:call) do |path, method: "GET", body: nil|
      if method == "PATCH"
        written[path] = body && body["body"].to_s
      end
      original.call(path, method: method, body: body)
    end

    ER.runner = fake
    ER.git_runner = ->(*_a) { true }
    out = StringIO.new
    code = ER.run(env: BASE_ENV, out: out)

    assert_equal 0, code, out.string

    comment_body = written["repos/o/r/issues/comments/7"]
    refute_nil comment_body, "必须 PATCH 登记评论，written=#{written.keys.inspect}"
    from_comment = ER.parse_block(comment_body)
    assert_equal ["冻结项"], from_comment["untested"], "升级必须采信登记评论而非正文副本"
    assert_equal true, from_comment["merged_into_main"]
    assert_equal "abc", from_comment["merge_commit"], "评论也必须写入合并事实"
    assert_equal "https://ci/1", from_comment["checks"], "评论也必须写入合并后的 CI 链接"

    issue_body = written["repos/o/r/issues/42"]
    refute_nil issue_body, "必须 PATCH issue 正文"
    from_issue = ER.parse_block(issue_body)
    assert_equal ["冻结项"], from_issue["untested"], "正文回填也必须携带登记值"
    assert_equal true, from_issue["merged_into_main"], "正文必须写为已合并"
    assert_equal "abc", from_issue["merge_commit"], "正文必须写入合并事实"
    assert_equal "https://ci/1", from_issue["checks"], "正文必须写入合并后的 CI 链接"
  ensure
    ER.runner = nil
    ER.git_runner = nil
  end

  # 登记评论作者不在 trusted_bots → 拒绝升级，零写入。
  def test_after_merge_rejects_untrusted_comment_author
    body = pre_block_body(merged: false, commit: nil, untested: [])
    fake = FakeGh.new(lambda do |key, _calls|
      case key
      when "GET repos/o/r/pulls/99" then BASE_RESPONSES["GET repos/o/r/pulls/99"]
      when "GET repos/o/r/issues/42" then {"state" => "closed", "state_reason" => "completed", "body" => body}
      when "GET repos/o/r/issues/comments/7"
        {"id" => 7, "user" => {"login" => "attacker"},
         "issue_url" => "https://api.github.com/repos/o/r/issues/42", "body" => body}
      when "PATCH repos/o/r/issues/comments/7" then {}
      when "PATCH repos/o/r/issues/42" then {}
      else raise "unexpected #{key}"
      end
    end)
    code = nil
    captured = StringIO.new
    orig = $stderr
    $stderr = captured
    begin
      code, calls, _ = run_with(fake, BASE_ENV)
      assert_equal 1, code, "非受信作者必须 fail-closed"
      assert(calls.none? { |m, _| m == "PATCH" }, "不得写入，calls=#{calls.inspect}")
    ensure
      $stderr = orig
    end
    assert_includes captured.string, "不在 trusted_bots 内"
  end

  # source_ref 指向别的 issue → 拒绝，防跨 issue 冒用。
  def test_after_merge_rejects_comment_from_other_issue
    body = pre_block_body(merged: false, commit: nil, untested: [])
    fake = FakeGh.new(lambda do |key, _calls|
      case key
      when "GET repos/o/r/pulls/99" then BASE_RESPONSES["GET repos/o/r/pulls/99"]
      when "GET repos/o/r/issues/42" then {"state" => "closed", "state_reason" => "completed", "body" => body}
      when "GET repos/o/r/issues/comments/7"
        {"id" => 7, "user" => {"login" => "github-actions[bot]"},
         "issue_url" => "https://api.github.com/repos/o/r/issues/999", "body" => body}
      when "PATCH repos/o/r/issues/comments/7" then {}
      when "PATCH repos/o/r/issues/42" then {}
      else raise "unexpected #{key}"
      end
    end)
    captured = StringIO.new
    orig = $stderr
    $stderr = captured
    begin
      code, calls, _ = run_with(fake, BASE_ENV)
      assert_equal 1, code
      assert(calls.none? { |m, _| m == "PATCH" })
    ensure
      $stderr = orig
    end
  end

  # 登记评论属于别的 PR → 拒绝：受信作者不证明「这条登记属于本次合并」。
  def test_after_merge_rejects_comment_from_other_pr
    body = pre_block_body(merged: false, commit: nil, untested: [])
    # 评论块自称 pr=98，本次合并是 99。
    stale = ER.evidence_block(issue_number: 42, pr_number: 98, merge_commit: nil,
      checks: "c", untested: [], source_ref: "https://github.com/o/r/issues/42#issuecomment-7",
      merged_into_main: false)
    fake = FakeGh.new(lambda do |key, _calls|
      case key
      when "GET repos/o/r/pulls/99" then BASE_RESPONSES["GET repos/o/r/pulls/99"]
      when "GET repos/o/r/issues/42" then {"state" => "closed", "state_reason" => "completed", "body" => body}
      when "GET repos/o/r/issues/comments/7"
        {"id" => 7, "user" => {"login" => "github-actions[bot]"},
         "issue_url" => "https://api.github.com/repos/o/r/issues/42",
         "body" => "```json evidence\n#{JSON.generate(stale)}\n```\n"}
      when "PATCH repos/o/r/issues/comments/7" then {}
      when "PATCH repos/o/r/issues/42" then {}
      else raise "unexpected #{key}"
      end
    end)
    captured = StringIO.new
    orig = $stderr
    $stderr = captured
    begin
      code, calls, _ = run_with(fake, BASE_ENV)
      assert_equal 1, code, "登记属于别的 PR 必须拒绝"
      assert(calls.none? { |m, _| m == "PATCH" }, "不得写入，calls=#{calls.inspect}")
    ensure
      $stderr = orig
    end
    assert_includes captured.string, "与本次合并的 PR"
  end

  # 登记块字段不全（缺 status/source_ref、untested 非数组）→ 拒绝，不写半截证据。
  # 结构不全 → 拒绝。每次只改一个字段，确保每条校验各自被真正覆盖：
  # 若把「缺 status」与「untested 非数组」混在一个夹具里，删掉任一校验仍会通过。
  def run_with_registered_block(broken)
    body = pre_block_body(merged: false, commit: nil, untested: [])
    fake = FakeGh.new(lambda do |key, _calls|
      case key
      when "GET repos/o/r/pulls/99" then BASE_RESPONSES["GET repos/o/r/pulls/99"]
      when "GET repos/o/r/issues/42" then {"state" => "closed", "state_reason" => "completed", "body" => body}
      when "GET repos/o/r/issues/comments/7"
        {"id" => 7, "user" => {"login" => "github-actions[bot]"},
         "issue_url" => "https://api.github.com/repos/o/r/issues/42",
         "body" => "```json evidence\n#{JSON.generate(broken)}\n```\n"}
      when "PATCH repos/o/r/issues/comments/7" then {}
      when "PATCH repos/o/r/issues/42" then {}
      else raise "unexpected #{key}"
      end
    end)
    captured = StringIO.new
    orig = $stderr
    $stderr = captured
    begin
      code, calls, _ = run_with(fake, BASE_ENV)
      [code, calls, captured.string]
    ensure
      $stderr = orig
    end
  end

  # 基线：完整合法块（untested 为空数组）必须能升级，证明后续拒绝是「单字段」造成的。
  def test_after_merge_accepts_complete_registered_block
    complete = ER.evidence_block(issue_number: 42, pr_number: 99, merge_commit: nil,
      checks: "c", untested: [], source_ref: "https://github.com/o/r/issues/42#issuecomment-7",
      merged_into_main: false)
    code, _calls, err = run_with_registered_block(complete)
    assert_equal 0, code, "完整块应通过，stderr=#{err}"
  end

  def test_after_merge_rejects_missing_status_only
    broken = ER.evidence_block(issue_number: 42, pr_number: 99, merge_commit: nil,
      checks: "c", untested: [], source_ref: "https://github.com/o/r/issues/42#issuecomment-7",
      merged_into_main: false).merge("status" => "")
    code, calls, err = run_with_registered_block(broken)
    assert_equal 1, code, "缺 status 必须拒绝"
    assert(calls.none? { |m, _| m == "PATCH" }, "不得写入，calls=#{calls.inspect}")
    assert_includes err, "缺 status"
  end

  def test_after_merge_rejects_non_array_untested_only
    broken = ER.evidence_block(issue_number: 42, pr_number: 99, merge_commit: nil,
      checks: "c", untested: [], source_ref: "https://github.com/o/r/issues/42#issuecomment-7",
      merged_into_main: false).merge("untested" => "not-an-array")
    code, calls, err = run_with_registered_block(broken)
    assert_equal 1, code, "untested 非数组必须拒绝"
    assert(calls.none? { |m, _| m == "PATCH" }, "不得写入，calls=#{calls.inspect}")
    assert_includes err, "untested 必须是数组"
  end

  def test_after_merge_rejects_missing_source_ref_only
    broken = ER.evidence_block(issue_number: 42, pr_number: 99, merge_commit: nil,
      checks: "c", untested: [], source_ref: "https://github.com/o/r/issues/42#issuecomment-7",
      merged_into_main: false).merge("source_ref" => "")
    code, calls, err = run_with_registered_block(broken)
    assert_equal 1, code, "缺 source_ref 必须拒绝"
    assert(calls.none? { |m, _| m == "PATCH" }, "不得写入，calls=#{calls.inspect}")
    assert_includes err, "缺 source_ref"
  end

  def test_after_merge_idempotent_on_true_block
    fake = FakeGh.new(
      "GET repos/o/r/pulls/99" => BASE_RESPONSES["GET repos/o/r/pulls/99"],
      "GET repos/o/r/issues/42" => {
        "state" => "closed", "state_reason" => "completed",
        "body" => pre_block_body(merged: true, commit: "abc")
      }
    )
    code, calls, out = run_with(fake, BASE_ENV)
    assert_equal 0, code
    assert_includes out, "已有有效 Evidence（幂等）"
    assert(calls.none? { |m, _| m != "GET" }, "幂等不得写入，calls=#{calls.inspect}")
  end
end
