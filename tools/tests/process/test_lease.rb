# frozen_string_literal: true

# Lease / Scope / RunRecord 迁移 / 写保护 / 协调者双认领 / docs-only 豁免的单元测试
# （M4x-Parallel-WP2，#220）。全部纯函数与本地文件，不访问网络。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"


class LeaseTest < Minitest::Test
  WHITELIST = ["ShiningRay"].freeze

  def lease_comment(id: 900, login: "ShiningRay", lease_id: "lease-1", state: "active",
                    issue: 1, branch: "feat/1", base_sha: "abc123")
    body = SebasAgents::Lease.comment_body(
      lease_id: lease_id, issue: issue, branch: branch, base_sha: base_sha,
      coordinator_id: "coord-a", host: "host-a", claimed_at: "2026-11-27T00:00:00Z", state: state
    )
    {"id" => id, "user" => {"login" => login}, "body" => body}
  end

  def test_comment_body_contains_marker_and_closed_field_set
    body = lease_comment["body"]
    assert_includes body, SebasAgents::Lease::MARKER
    credential = JSON.parse(body.split("```json sebas-lease\n").last.split("\n```").first)
    assert_equal %w[lease_id issue branch base_sha coordinator_id host state claimed_at].sort,
                 credential.keys.sort
    assert_equal "active", credential["state"]
  end

  def test_uniqueness_single_active_lease_is_returned
    credential = SebasAgents::Lease.active_lease([lease_comment], author_whitelist: WHITELIST)
    assert_equal "lease-1", credential["lease_id"]
    assert_equal "feat/1", credential["branch"]
  end

  def test_multiple_active_leases_fail_closed
    comments = [lease_comment(id: 900), lease_comment(id: 901, lease_id: "lease-2")]
    error = assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::Lease.active_lease(comments, author_whitelist: WHITELIST)
    end
    assert_includes error.message, "2 份有效租约"
  end

  def test_released_lease_does_not_count_as_active
    comments = [lease_comment(id: 900, state: "released"), lease_comment(id: 901, lease_id: "lease-2", state: "released")]
    assert_nil SebasAgents::Lease.active_lease(comments, author_whitelist: WHITELIST)
  end

  def test_author_outside_whitelist_fail_closed
    error = assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::Lease.active_lease([lease_comment(login: "nobody")], author_whitelist: WHITELIST)
    end
    assert_includes error.message, "coordinators 白名单"
  end

  def test_orphan_label_detection
    # 有标签、无有效凭据 → invalid_plan（F7）
    error = assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::Lease.assert_no_orphan_label(label_present: true, active_lease: nil, issue_number: 1)
    end
    assert_includes error.message, "无有效租约凭据"
    # 有标签且有凭据 → 通过
    SebasAgents::Lease.assert_no_orphan_label(
      label_present: true, active_lease: {"lease_id" => "lease-1"}, issue_number: 1)
    # 无标签 → 不判定
    SebasAgents::Lease.assert_no_orphan_label(label_present: false, active_lease: nil, issue_number: 1)
  end

  def test_find_by_lease_id_reuses_existing_comment_without_repost
    comments = [lease_comment(id: 900), lease_comment(id: 901, lease_id: "lease-2")]
    found = SebasAgents::Lease.find_by_lease_id(comments, "lease-1", author_whitelist: WHITELIST)
    assert_equal 900, found[0]
    assert_equal "lease-1", found[1]["lease_id"]
    assert_nil SebasAgents::Lease.find_by_lease_id(comments, "missing", author_whitelist: WHITELIST)
  end

  def test_malformed_lease_body_fail_closed
    malformed = {"id" => 902, "user" => {"login" => "ShiningRay"},
                 "body" => "#{SebasAgents::Lease::MARKER}\n不是凭据\n"}
    error = assert_raises(SebasAgents::InvalidPlan) do
      SebasAgents::Lease.active_lease([malformed], author_whitelist: WHITELIST)
    end
    assert_includes error.message, "sebas-lease"
  end
end

class ScopeTest < Minitest::Test
  def normalize(values)
    SebasAgents::Policy::Scope.normalize(values, issue_number: 1)
  end

  def test_normalize_appends_trailing_slash_and_keeps_order
    assert_equal ["src/store/", "spec/store/", "docs/"], normalize(["src/store", "spec/store/", "docs/"])
  end

  def test_normalize_rejects_illegal_values
    assert_raises(SebasAgents::InvalidPlan) { normalize([]) }
    assert_raises(SebasAgents::InvalidPlan) { normalize([1]) }
    assert_raises(SebasAgents::InvalidPlan) { normalize(["../secret"]) }
    assert_raises(SebasAgents::InvalidPlan) { normalize(["/abs"]) }
  end

  def test_conflict_by_prefix_containment
    conflict = SebasAgents::Policy::Scope
    assert conflict.conflict?(["src/"], ["src/bus/"])       # 前缀互相包含
    assert conflict.conflict?(["src/bus/"], ["src/bus/x.cr/"])
    refute conflict.conflict?(["src/bus/"], ["src/keys/"])  # 兄弟目录不冲突
    refute conflict.conflict?(nil, ["src/"])                # 未声明不参与
    refute conflict.conflict?(["docs/"], nil)
  end

  def test_filter_candidates_marks_conflicting_and_missing_scope
    candidates = [
      make_candidate(1, ["docs/"]),
      make_candidate(2, ["src/"]),
      make_candidate(3, nil)
    ]
    leases = [{issue: 9, scope: ["docs/proposals/"]}]
    ready, excluded = SebasAgents::Policy::Scope.filter_candidates(candidates, leases)
    # 容量 >1 语义：与在途租约重叠 → 排除；缺 scope → 独占语义，同样排除
    assert_equal [2], ready.map(&:number)
    assert_includes excluded.map { |row| row[:issue] }, 1
    assert_includes excluded.map { |row| row[:issue] }, 3
  end

  def make_candidate(number, scope)
    require "ostruct"
    automation = {
      "schema" => 1, "kind" => "work_package", "order" => [4, 1],
      "depends_on" => [], "external" => []
    }
    automation["scope"] = scope unless scope.nil?
    OpenStruct.new(number: number, automation: automation)
  end
end

class RunRecordMigrationTest < Minitest::Test
  def test_inactive_v1_record_auto_migrates_and_old_path_removed
    Dir.mktmpdir do |dir|
      legacy = File.join(dir, "run.json")
      File.write(legacy, JSON.generate({
        "schema" => 1, "issue" => 7, "branch" => "feat/7", "phase" => "released", "attempts" => 1
      }), encoding: "UTF-8")

      migrated = SebasAgents::RunRecord.migrate_legacy!(legacy, runs_dir: File.join(dir, "runs"))
      assert migrated
      refute File.exist?(legacy), "旧路径必须删除（搬迁并双读一个版本）"
      target = File.join(dir, "runs", "7.json")
      assert File.exist?(target)
      data = JSON.parse(File.read(target, encoding: "UTF-8"))
      assert_equal 2, data["schema"]
      assert_equal "released", data["phase"]
    end
  end

  def test_active_v1_record_fail_closed_requires_manual_confirmation
    Dir.mktmpdir do |dir|
      legacy = File.join(dir, "run.json")
      File.write(legacy, JSON.generate({
        "schema" => 1, "issue" => 7, "branch" => "feat/7", "phase" => "claimed", "attempts" => 0
      }), encoding: "UTF-8")

      error = assert_raises(SebasAgents::InvalidPlan) do
        SebasAgents::RunRecord.migrate_legacy!(legacy, runs_dir: File.join(dir, "runs"))
      end
      assert_includes error.message, "人工确认"
      assert File.exist?(legacy), "fail-closed：旧记录不得被吞"
    end
  end

  def test_active_records_enforces_schema_2
    Dir.mktmpdir do |dir|
      runs = File.join(dir, "runs")
      FileUtils.mkdir_p(runs)
      File.write(File.join(runs, "7.json"), JSON.generate({
        "schema" => 2, "issue" => 7, "phase" => "claimed"
      }), encoding: "UTF-8")
      assert_equal 7, SebasAgents::RunRecord.active_records(runs).first["issue"]

      # schema 非 2 → invalid_plan（CR-10：未知 schema 一律拒绝）
      File.write(File.join(runs, "8.json"), JSON.generate({"schema" => 1, "issue" => 8, "phase" => "released"}),
        encoding: "UTF-8")
      assert_raises(SebasAgents::InvalidPlan) { SebasAgents::RunRecord.active_records(runs) }
      File.write(File.join(runs, "8.json"), JSON.generate({"schema" => 99, "issue" => 8, "phase" => "claimed"}),
        encoding: "UTF-8")
      assert_raises(SebasAgents::InvalidPlan) { SebasAgents::RunRecord.active_records(runs) }
    end
  end

  def test_migration_window_capacity_one_invalid_plan_on_multi_active
    Dir.mktmpdir do |dir|
      runs = File.join(dir, "runs")
      FileUtils.mkdir_p(runs)
      File.write(File.join(runs, "7.json"), JSON.generate({"schema" => 2, "issue" => 7, "phase" => "claimed"}),
        encoding: "UTF-8")
      File.write(File.join(runs, "8.json"), JSON.generate({"schema" => 2, "issue" => 8, "phase" => "claimed"}),
        encoding: "UTF-8")
      legacy = File.join(dir, "run.json")
      File.write(legacy, JSON.generate({"schema" => 2, "issue" => 99, "phase" => "claimed"}), encoding: "UTF-8")

      # 迁移窗口（legacy run.json 在场）内两份活动记录 → 容量 1 → invalid_plan
      error = assert_raises(SebasAgents::InvalidPlan) do
        cli_record_for_with_migration(dir, legacy)
      end
      assert_includes error.message, "迁移期容量"
    end
  end

  # 复刻 record_for 的迁移窗口语义：legacy 在场 + runs/ 多活动 → invalid_plan
  def cli_record_for_with_migration(dir, legacy)
    active = SebasAgents::RunRecord.active_records(File.join(dir, "runs"))
    if active.length > 1 && File.exist?(legacy)
      raise SebasAgents::InvalidPlan, "迁移窗口内存在 #{active.length} 份活动运行记录（迁移期容量 1），需人工确认迁移"
    end
    active.first
  end
end

# 写守卫（Q1=B 代价项）：租约评论的命令形态必须落在既有
# create_comment / update_comment 写意图的放行正则内，其余命令仍被拦截。
class LeaseWriteGuardTest < Minitest::Test
  RUNNER = SebasAgents::CommandRunner

  def assert_allowed(intent, command_string)
    pattern = RUNNER::ALLOWED_WRITES[intent]
    assert !pattern.nil? && pattern.match?(command_string),
      "#{intent} 应放行：#{command_string}"
  end

  def assert_blocked(command_string)
    intents = %i[add_label remove_label set_status set_type create_comment update_comment pin_comment]
    matched = intents.any? do |intent|
      pattern = RUNNER::ALLOWED_WRITES[intent]
      !pattern.nil? && pattern.match?(command_string)
    end
    refute matched, "应被拦截：#{command_string}"
  end

  def test_lease_comment_post_matches_create_comment_intent
    assert_allowed :create_comment,
      "gh api repos/o/r/issues/1/comments -f body=#{SebasAgents::Lease::MARKER}\nlease"
  end

  def test_lease_comment_update_matches_update_comment_intent
    assert_allowed :update_comment,
      "gh api -X PATCH repos/o/r/issues/comments/900 -f body=#{SebasAgents::Lease::MARKER}\nreleased"
  end

  def test_unrelated_gh_writes_still_blocked
    assert_blocked "gh api -X DELETE repos/o/r/issues/comments/900"
    assert_blocked "gh issue close 1 --repo o/r"
  end
end


# coordinator 串行认领集成测试（M4x-Parallel-WP2，#220；issue 验收第 3/4 条）。
# 有状态假 gh：评论 POST/PATCH 落内存仓库，GET 返回该卡全量；
# fail_comments_get_on 指定第 N 次 comments GET 注入失败（故障注入）。
class FakeGhStore
  attr_reader :comments, :labels

  def initialize(fail_comments_get_on: [])
    @comments = []
    @labels = Hash.new { |hash, key| hash[key] = [] }
    @statuses = {}
    @next_id = 900
    @fail_on = fail_comments_get_on
    @comments_get_count = 0
  end

  def clear_injected_failures
    @fail_on = []
  end

  def call(argv)
    joined = argv.join(" ")
    if argv[0] == "gh" && argv[1] == "api" && argv[2] == "-X" && argv[3] == "PATCH" &&
       joined.include?("issues/comments/")
      comment = @comments.find { |item| item["id"] == argv[6].to_i }
      return JSON.generate({id: comment ? comment["id"] : nil}) unless comment

      comment["body"] = argv[6].to_s.sub(/\Abody=/, "")
      return JSON.generate({id: comment["id"]})
    end
    # POST 评论：登记新评论（作者固定白名单成员）。
    # 路径匹配锚 argv[2]（body 多行，joined 以 body 结尾不能用 \z 锚）。
    # 注意用 match（非 match?）取捕获——match? 不回填 Regexp.last_match。
    if argv[0] == "gh" && argv[1] == "api" && argv[2] != "-X" &&
       (m = argv[2].match(%r{repos/o/r/issues/(\d+)/comments\z}))
      issue_number = m[1].to_i
      @next_id += 1
      @comments << {"id" => @next_id, "user" => {"login" => "ShiningRay"},
                    "body" => argv[4].to_s.sub(/\Abody=/, ""), :issue_number => issue_number}
      return JSON.generate({id: @next_id})
    end
    # GET 评论（分页，可能注入失败）
    if argv[0] == "gh" && argv[1] == "api" && argv[2] != "-X" &&
       (m = joined.match(%r{repos/o/r/issues/(\d+)/comments\?}))
      @comments_get_count += 1
      if @fail_on.include?(@comments_get_count)
        raise SebasAgents::CommandError.new("injected comments read failure", command: argv)
      end
      issue_number = Regexp.last_match(1).to_i
      list = @comments.select { |item| item[:issue_number] == issue_number }
      return JSON.generate(list)
    end
    # 读单卡（label_present?）
    if (m = joined.match(%r{repos/o/r/issues/(\d+)\z}))
      issue_number = Regexp.last_match(1).to_i
      return JSON.generate({
        "labels" => @labels[issue_number].map { |name| {"name" => name} },
        "status" => {"name" => @statuses[issue_number].to_s}
      })
    end
    # PATCH status
    if joined.include?("repos/o/r/issues/") && argv.include?("-f") &&
       (status_arg = argv.find { |arg| arg.start_with?("status=") })
      m = joined.match(%r{repos/o/r/issues/(\d+)\s})
      @statuses[Regexp.last_match(1).to_i] = status_arg.sub(/\Astatus=/, "")
      return "{}"
    end
    # 标签增删
    if argv[0] == "gh" && argv[1] == "issue" && argv[2] == "edit"
      issue_number = argv[3].to_i
      if (i = argv.index("--add-label"))
        @labels[issue_number] << argv[i + 1]
      elsif (i = argv.index("--remove-label"))
        @labels[issue_number] -= [argv[i + 1]]
      end
      return "{}"
    end

    ""
  end

  def active_lease_count(issue_number)
    @comments.count do |item|
      item[:issue_number] == issue_number && item["body"].include?('"state": "active"')
    end
  end

  # 测试直塞凭据（模拟「有凭据无本机记录」的外来租约）。
  def manual_post(issue_number, body)
    @next_id += 1
    @comments << {"id" => @next_id, "user" => {"login" => "ShiningRay"},
                  "body" => body, :issue_number => issue_number}
    @next_id
  end
end

class CoordinatorClaimTest < Minitest::Test
  # 本文件不依赖主测试的 SnapshotHelpers：本地定义 milestone / snapshot 助手。
  def milestone(number:, order:, track:, open_issues:)
    {"number" => number, "title" => "M#{number}", "state" => "open",
     "order" => order, "track" => track, "open_issues" => open_issues,
     "description" => "order: #{order}\ntrack: #{track}\n"}
  end

  def snapshot(issues:, milestones:)
    {
      "repo" => "o/r",
      "main_sha" => "deadbeef",
      "milestones" => milestones,
      "issues" => issues,
      "pull_requests" => [],
      "maintainers" => ["ShiningRay"],
      "source_authors" => {},
      "gates" => {},
      "externals" => {},
      "trusted_bots" => [],
      "source_bodies" => {}
    }
  end

  def docs_issue(number)
    automation = {"schema" => 1, "kind" => "work_package", "order" => [4, 6, 1],
                  "depends_on" => [], "external" => [], "scope" => ["docs/"]}
    body = "## 目标\n测试\n\n```json automation\n#{JSON.pretty_generate(automation)}\n```\n"
    {"number" => number, "title" => "docs card #{number}", "state" => "OPEN",
     "state_reason" => nil, "body" => body, "labels" => [], "milestone" => 1,
     "status" => nil, "blocked_by" => []}
  end

  def make_fake(store)
    fake = Class.new(SebasAgents::CommandRunner)
    fake.define_method(:run!) { |*argv, chdir: Dir.pwd| store.call(argv) }
    fake
  end

  def with_pilot_repo
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(".github")
        File.write(".github/agents.yml", "coordinators:\n  - ShiningRay\n", encoding: "UTF-8")
        data = snapshot(issues: [docs_issue(11), docs_issue(12), docs_issue(13)],
          milestones: [milestone(number: 1, order: "4x", track: "parallel", open_issues: 3)])
        snap = File.join(dir, "snapshot.json")
        File.write(snap, JSON.generate(data), encoding: "UTF-8")
        yield snap
      end
    end
  end

  # 验收第 3 条：coordinator 串行认领两张 docs 卡，各自独立写 lease，两次回读均确认。
  # 注：fixture 为静态快照，卡 11 的 status 不随认领变化——试点豁免（docs-only 对）
  # 语义由 claim_blocker 单测路径覆盖，这里验证 lease 写入、独立凭据与回读链路。
  def test_coordinator_serial_dual_claim_writes_independent_leases
    with_pilot_repo do |snap|
      store = FakeGhStore.new
      fake = make_fake(store)
      cli = SebasAgents::CLI.new(out: StringIO.new, err: StringIO.new)
      cli.define_singleton_method(:runner) { |_options| fake.new(dry_run: false) }

      status1 = cli.run(["claim", "11", "--snapshot", snap, "--apply"])
      assert_equal 0, status1
      status2 = cli.run(["claim", "12", "--snapshot", snap, "--apply"])
      assert_equal 0, status2

      assert_equal 1, store.active_lease_count(11), "卡 11 恰一条 active 租约"
      assert_equal 1, store.active_lease_count(12), "卡 12 恰一条 active 租约"
      record1 = JSON.parse(File.read(File.join(".sebas-agent", "runs", "11.json"), encoding: "UTF-8"))
      record2 = JSON.parse(File.read(File.join(".sebas-agent", "runs", "12.json"), encoding: "UTF-8"))
      assert_equal "claimed", record1["phase"]
      assert_equal "claimed", record2["phase"]
      refute_equal record1["lease_id"], record2["lease_id"]
      assert_includes store.labels[11], "agent:in-progress"
      assert_includes store.labels[12], "agent:in-progress"
    end
  end

  # 验收第 4 条（故障注入）：标签写成功但评论回读失败 → aborted + lease_id 留痕；
  # 重跑 claim 按 lease_id 对账复用既有凭据恢复 claimed，不产生第二条租约（F4 不双开）。
  def test_readback_failure_recovers_via_lease_id_without_double_lease
    with_pilot_repo do |snap|
      store = FakeGhStore.new(fail_comments_get_on: [3]) # 第 3 次 comments GET = 回读
      fake = make_fake(store)
      cli = SebasAgents::CLI.new(out: StringIO.new, err: StringIO.new)
      cli.define_singleton_method(:runner) { |_options| fake.new(dry_run: false) }

      status = cli.run(["claim", "13", "--snapshot", snap, "--apply"])
      assert_equal 1, status
      assert_equal 1, store.active_lease_count(13), "凭据已发出（恰一条）"
      record = JSON.parse(File.read(File.join(".sebas-agent", "runs", "13.json"), encoding: "UTF-8"))
      assert_equal "aborted", record["phase"]
      assert_equal true, record["label_written"]

      # 恢复路径：重跑 claim——预检命中既有凭据 + 本机 aborted 记录 → 复用不重发
      store.clear_injected_failures
      out = StringIO.new
      cli.instance_variable_set(:@out, out)
      recovered = cli.run(["claim", "13", "--snapshot", snap, "--apply"])
      STDERR.puts "RECOVERY payload: #{out.string[0, 300]}" unless recovered.zero?
      assert_equal 0, recovered
      assert_equal 1, store.active_lease_count(13), "恢复复用凭据，不得双开"
      record = JSON.parse(File.read(File.join(".sebas-agent", "runs", "13.json"), encoding: "UTF-8"))
      assert_equal "claimed", record["phase"]
    end
  end

  # 验收：试点期无重复分支、无重复 PR、无 lease 冲突——重复认领同一张卡必须拒绝。
  def test_duplicate_claim_on_leased_card_is_refused
    with_pilot_repo do |snap|
      store = FakeGhStore.new
      fake = make_fake(store)
      cli = SebasAgents::CLI.new(out: StringIO.new, err: StringIO.new)
      cli.define_singleton_method(:runner) { |_options| fake.new(dry_run: false) }
      assert_equal 0, cli.run(["claim", "11", "--snapshot", snap, "--apply"])

      # 另一张卡没有本地归属记录却已持凭据 → 拒绝（fail-closed，不接管）
      # 先构造：手动把 12 的凭据评论塞进 store，模拟「有凭据无本机记录」
      store.manual_post(12, SebasAgents::Lease.comment_body(
        lease_id: "ghost-1", issue: 12, branch: "feat/12", base_sha: "abc",
        coordinator_id: "coord-x", host: "host-x", claimed_at: "2026-11-27T00:00:00Z"))
      status = cli.run(["claim", "12", "--snapshot", snap, "--apply"])
      assert_equal 1, status
    end
  end
end

# 试点豁免（§8 阶段 2）：两张 docs-only 工作包卡可并行；claim --dry-run 验证
# claim_blocker 的「已有活动认领」判定放行 docs-only 对、拒绝非 docs 对。
class PilotExemptionTest < Minitest::Test
  def docs_issue(number, status: nil, scope: ["docs/guide/"])
    automation = {"schema" => 1, "kind" => "work_package", "order" => [4, 6, 1],
                  "depends_on" => [], "external" => [], "scope" => scope}
    body = "## 目标\n测试\n\n```json automation\n#{JSON.pretty_generate(automation)}\n```\n"
    {"number" => number, "title" => "docs card #{number}", "state" => "OPEN",
     "state_reason" => nil, "body" => body, "labels" => [], "milestone" => 1,
     "status" => status, "blocked_by" => []}
  end

  def code_issue(number, status: nil)
    body = "## 目标\n测试\n\n```json automation\n" +
      JSON.pretty_generate({"schema" => 1, "kind" => "work_package", "order" => [4, 6, 2],
                            "depends_on" => [], "external" => []}) + "\n```\n"
    {"number" => number, "title" => "code card #{number}", "state" => "OPEN",
     "state_reason" => nil, "body" => body, "labels" => [], "milestone" => 1,
     "status" => status, "blocked_by" => []}
  end

  def milestone(number:, order:, track:, open_issues:)
    {"number" => number, "title" => "M#{number}", "state" => "open", "order" => order,
     "track" => track, "open_issues" => open_issues,
     "description" => "order: #{order}\ntrack: #{track}\n"}
  end

  def snapshot(issues:)
    {"repo" => "o/r", "main_sha" => "deadbeef",
     "milestones" => [milestone(number: 1, order: "4x", track: "parallel", open_issues: issues.length)],
     "issues" => issues, "pull_requests" => [], "maintainers" => ["ShiningRay"],
     "source_authors" => {}, "gates" => {}, "externals" => {}, "trusted_bots" => [],
     "source_bodies" => {}}
  end

  def run_dry(data, number)
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(".github")
        File.write(".github/agents.yml", "coordinators:\n  - ShiningRay\n", encoding: "UTF-8")
        snap = File.join(dir, "snapshot.json")
        File.write(snap, JSON.generate(data), encoding: "UTF-8")
        cli = SebasAgents::CLI.new(out: StringIO.new, err: StringIO.new)
        cli.define_singleton_method(:runner) { |_options| Class.new(SebasAgents::CommandRunner).new(dry_run: false) }
        cli.instance_variable_set(:@out, StringIO.new)
        status = cli.run(["claim", number.to_s, "--snapshot", snap])
        payload = JSON.parse(cli.instance_variable_get(:@out).string)
        [status, payload]
      end
    end
  end

  def test_docs_only_pair_is_exempt_from_single_active_check
    # 目录不重叠（guide/ vs reference/）→ 试点豁免 → 可并行
    data = snapshot(issues: [
      docs_issue(11, status: "In progress", scope: ["docs/guide/"]),
      docs_issue(12, scope: ["docs/reference/"])
    ])
    status, payload = run_dry(data, 12)
    assert_equal 0, status
    assert_equal true, payload["ok"], payload["reasons"].inspect
  end

  def test_overlapping_docs_pair_is_refused
    # 目录重叠（都是 guide/）→ 冲突 → 拒绝（CR-15）
    data = snapshot(issues: [
      docs_issue(11, status: "In progress", scope: ["docs/guide/"]),
      docs_issue(12, scope: ["docs/guide/"])
    ])
    status, payload = run_dry(data, 12)
    assert_equal 1, status
    assert_equal false, payload["ok"]
  end

  def test_non_docs_pair_is_refused
    data = snapshot(issues: [code_issue(11, status: "In progress"), code_issue(12)])
    status, payload = run_dry(data, 12)
    assert_equal 1, status
    assert_equal false, payload["ok"]
    assert_includes payload["reasons"].join, "已有活动认领"
  end
end
