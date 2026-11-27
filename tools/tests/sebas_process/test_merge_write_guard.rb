# frozen_string_literal: true

# 合并与 update-branch 的写守卫（M4x-Parallel-WP3，#221 §7.2）。
#
# 这两条是仓库里仅有的、能改变 main 的命令。放行条件必须是**完整形态**：
# 少了 --match-head-commit 就等于允许把没核验过的提交合进去，所以正则
# 不接受「近似」写法。
#
# 断言看「子进程是否真的被调用」，不看 runner.calls：后者在拦截前就记录，
# 用它断言会把「被拦」和「被执行」看成同一件事。

require "open3"

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

class MergeWriteGuardTest < Minitest::Test
  SHA = "b107e3536deabb8ce8f83b6d2a5d29ffdb3f6e62"

  def runner
    SebasAgents::CommandRunner.new(dry_run: true)
  end

  # 包住一次 capture，返回真正执行过的命令列表。
  def executed
    calls = []
    Open3.singleton_class.alias_method(:__guard_capture3, :capture3)
    Open3.define_singleton_method(:capture3) do |*argv, **_opts|
      calls << argv
      ["", "", Struct.new(:success?).new(true)]
    end
    begin
      yield
    ensure
      Open3.singleton_class.alias_method(:capture3, :__guard_capture3)
    end
    calls
  end

  def merge_cmd(number: 289, sha: SHA, repo: "o/r")
    ["gh", "pr", "merge", number.to_s, "--repo", repo, "--squash", "--match-head-commit", sha]
  end

  def test_merge_is_blocked_without_intent
    runs = executed { runner.capture(*merge_cmd) }
    assert_empty runs, "dry-run 下未授权写命令必须被拦"
  end

  def test_merge_allowed_with_intent_and_full_form
    r = runner
    runs = executed { r.with_write(:merge_pr) { r.capture(*merge_cmd) } }
    assert_equal [merge_cmd], runs
  end

  def test_merge_without_match_head_commit_is_blocked
    r = runner
    runs = executed do
      r.with_write(:merge_pr) do
        r.capture("gh", "pr", "merge", "289", "--repo", "o/r", "--squash")
      end
    end
    assert_empty runs, "缺 --match-head-commit 等于允许合并未核验提交，必须拦"
  end

  def test_merge_without_squash_is_blocked
    r = runner
    runs = executed do
      r.with_write(:merge_pr) do
        r.capture("gh", "pr", "merge", "289", "--repo", "o/r", "--match-head-commit", SHA)
      end
    end
    assert_empty runs, "仓库 squash-only，非 squash 形态不放行"
  end

  def test_merge_with_merge_commit_flag_is_blocked
    r = runner
    runs = executed do
      r.with_write(:merge_pr) do
        r.capture("gh", "pr", "merge", "289", "--repo", "o/r", "--merge", "--match-head-commit", SHA)
      end
    end
    assert_empty runs
  end

  def test_merge_with_extra_flags_is_blocked
    r = runner
    runs = executed do
      r.with_write(:merge_pr) { r.capture(*merge_cmd, "--admin") }
    end
    assert_empty runs, "多余参数必须让整条命令不匹配（不放行 --admin 之类）"
  end

  # 授权意图不可串用：拿 add_label 的意图发合并命令必须被拦。
  def test_intent_is_not_interchangeable
    r = runner
    runs = executed { r.with_write(:add_label) { r.capture(*merge_cmd) } }
    assert_empty runs
  end

  def test_update_branch_needs_own_intent
    r = runner
    cmd = ["gh", "pr", "update-branch", "289", "--repo", "o/r"]
    runs = executed do
      r.capture(*cmd)
      r.with_write(:update_branch) { r.capture(*cmd) }
    end
    assert_equal [cmd], runs, "只有带 :update_branch 意图的那次执行"
  end

  # gateway 侧：不传 allow_write 时不得真正执行（默认 dry-run 语义）。
  def test_gateway_merge_defaults_to_no_write
    r = runner
    gateway = SebasAgents::GithubGateway.new(r, repo: "o/r")
    runs = executed { gateway.merge_pr(289, SHA) }
    assert_empty runs
  end
end
