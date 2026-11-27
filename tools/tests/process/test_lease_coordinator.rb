# frozen_string_literal: true

# 协调者串行认领与 docs-only 并行豁免的集成测试（M4x-Parallel-WP2，#220）。
#
# FakeGhStore 是有状态的假 gh：评论 POST/PATCH 落内存仓库，GET 返回该卡全量，
# fail_comments_get_on 可按第 N 次 comments GET 注入失败。用它验证
# 「写入成功但回读失败」时不得重复发租约，以及双 docs-only 卡的并行豁免
# 只在 scope 不重叠时成立。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

# 有状态的假 gh：评论写进内存仓库，GET 回读该卡全量。
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

class PilotExemptionTest < Minitest::Test

  # --- docs-only 并行豁免 ---

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
