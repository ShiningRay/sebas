# frozen_string_literal: true

# 跨机 ref 锁（#306）：GitHub git-ref 创建即原子 CAS 的行为与 CLI 接线。
#
# FakeRefGhStore 是有状态的假 gh：在 FakeGhStore 的评论/状态/标签路由之外
# 增加 git commits/refs 端点。refs POST 模拟服务端语义——同名 ref 已存在即
# 抛 CommandError（HTTP 422 already exists），并全程持 Mutex，供真双线程
# 争锁用例证明「恰一个胜出」。

require_relative "../support/boot"
require_relative "../../agents/lib/sebas_agents"

# 有状态的假 gh：评论/状态/标签 + 内存 ref 表。
class FakeRefGhStore
  attr_reader :comments, :labels, :statuses, :refs

  def initialize
    @mutex = Mutex.new
    @comments = []
    @labels = Hash.new { |hash, key| hash[key] = [] }
    @statuses = {}
    @refs = {}     # ref 名 => commit sha
    @commits = {}  # sha => message（锁凭据 JSON）
    @next_id = 900
  end

  def call(argv)
    @mutex.synchronize { route(argv) }
  end

  def route(argv)
    joined = argv.join(" ")
    # POST git/commits：建锁凭据 commit。
    if argv[0] == "gh" && argv[1] == "api" && argv[2].to_s.match?(%r{repos/o/r/git/commits\z})
      sha = format("%040x", @commits.size + 1)
      @commits[sha] = argv.find { |arg| arg.to_s.start_with?("message=") }.to_s.sub(/\Amessage=/, "")
      return JSON.generate({"sha" => sha})
    end
    # GET git/commits/<sha>：读锁凭据。
    if argv[0] == "gh" && argv[1] == "api" && argv[2] != "-X" &&
       (m = argv[2].to_s.match(%r{repos/o/r/git/commits/([0-9a-f]+)\z}))
      return JSON.generate({"message" => @commits[m[1]] || ""})
    end
    # POST git/refs：CAS——已存在即 422 already exists。
    if argv[0] == "gh" && argv[1] == "api" && argv[2].to_s.match?(%r{repos/o/r/git/refs\z})
      ref = argv.find { |arg| arg.to_s.start_with?("ref=") }.to_s.sub(/\Aref=/, "")
      if @refs.key?(ref)
        raise SebasAgents::CommandError.new(
          "gh: HTTP 422: Unprocessable Entity: \"Reference already exists\" (#{ref})",
          command: argv
        )
      end
      @refs[ref] = argv.find { |arg| arg.to_s.start_with?("sha=") }.to_s.sub(/\Asha=/, "")
      return JSON.generate({"ref" => ref})
    end
    # GET git/matching-refs/<prefix>
    if argv[0] == "gh" && argv[1] == "api" &&
       (m = argv[2].to_s.match(%r{repos/o/r/git/matching-refs/(\S+)\z}))
      prefix = m[1].gsub("%2F", "/")
      rows = @refs.select { |name, _| name.start_with?(prefix) }
                  .map { |name, sha| {"ref" => name, "object" => {"sha" => sha}} }
      return JSON.generate(rows)
    end
    # DELETE git/refs/<ref>
    if argv[0] == "gh" && argv[1] == "api" && argv[2] == "-X" && argv[3] == "DELETE" &&
       (m = argv[4].to_s.match(%r{repos/o/r/git/refs/(\S+)\z}))
      @refs.delete(m[1].gsub("%2F", "/"))
      return "{}"
    end
    # POST 评论（作者固定白名单成员）
    if argv[0] == "gh" && argv[1] == "api" && argv[2] != "-X" &&
       (m = argv[2].match(%r{repos/o/r/issues/(\d+)/comments\z}))
      @next_id += 1
      @comments << {"id" => @next_id, "user" => {"login" => "ShiningRay"},
                    "body" => argv[4].to_s.sub(/\Abody=/, ""), :issue_number => m[1].to_i}
      return JSON.generate({id: @next_id})
    end
    # GET 评论（分页）
    if argv[0] == "gh" && argv[1] == "api" && argv[2] != "-X" &&
       (m = joined.match(%r{repos/o/r/issues/(\d+)/comments\?}))
      list = @comments.select { |item| item[:issue_number] == Regexp.last_match(1).to_i }
      return JSON.generate(list)
    end
    # 读单卡（label_present? / status_of）
    if (m = joined.match(%r{repos/o/r/issues/(\d+)\z}))
      number = Regexp.last_match(1).to_i
      return JSON.generate({
        "labels" => @labels[number].map { |name| {"name" => name} },
        "status" => {"name" => @statuses[number].to_s}
      })
    end
    # PATCH status
    if joined.include?("repos/o/r/issues/") && argv.include?("-f") &&
       (status_arg = argv.find { |arg| arg.start_with?("status=") })
      @statuses[joined.match(%r{repos/o/r/issues/(\d+)\s}).to_a[1].to_i] = status_arg.sub(/\Astatus=/, "")
      return "{}"
    end
    # 标签增删
    if argv[0] == "gh" && argv[1] == "issue" && argv[2] == "edit"
      number = argv[3].to_i
      if (i = argv.index("--add-label"))
        @labels[number] << argv[i + 1]
      elsif (i = argv.index("--remove-label"))
        @labels[number] -= [argv[i + 1]]
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
end

class RefLockTest < Minitest::Test
  def milestone(number:, order:, track:, open_issues:)
    {"number" => number, "title" => "M#{number}", "state" => "open",
     "order" => order, "track" => track, "open_issues" => open_issues,
     "description" => "order: #{order}\ntrack: #{track}\n"}
  end

  def snapshot(issues:, milestones:, pull_requests: [])
    {
      "repo" => "o/r", "main_sha" => "deadbeef", "milestones" => milestones,
      "issues" => issues, "pull_requests" => pull_requests,
      "maintainers" => ["ShiningRay"], "source_authors" => {}, "gates" => {},
      "externals" => {}, "trusted_bots" => [], "source_bodies" => {}
    }
  end

  def docs_issue(number, status: nil)
    automation = {"schema" => 1, "kind" => "work_package", "order" => [4, 6, 1],
                  "depends_on" => [], "external" => [], "scope" => ["docs/"]}
    body = "## 目标\n测试\n\n```json automation\n#{JSON.pretty_generate(automation)}\n```\n"
    {"number" => number, "title" => "docs card #{number}", "state" => "OPEN",
     "state_reason" => nil, "body" => body, "labels" => [], "milestone" => 1,
     "status" => status, "blocked_by" => []}
  end

  def make_fake(store)
    fake = Class.new(SebasAgents::CommandRunner)
    fake.define_method(:run!) { |*argv, chdir: Dir.pwd| store.call(argv) }
    fake
  end

  def cli(store, out)
    runner = make_fake(store).new(dry_run: false)
    instance = SebasAgents::CLI.new(out: out, err: StringIO.new)
    instance.define_singleton_method(:runner) { |_options| runner }
    instance
  end

  def with_repo(agents_yml: "coordinators:\n  - ShiningRay\n")
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(".github")
        File.write(".github/agents.yml", agents_yml, encoding: "UTF-8")
        data = snapshot(issues: [docs_issue(11), docs_issue(12), docs_issue(13)],
          milestones: [milestone(number: 1, order: "4x", track: "parallel", open_issues: 3)])
        snap = File.join(dir, "snapshot.json")
        File.write(snap, JSON.generate(data), encoding: "UTF-8")
        yield snap, dir
      end
    end
  end

  def lock_credential(pid: Process.pid, host: Socket.gethostname,
                      created_at: Time.now.utc.iso8601, lock_id: "seed-lock", issue: 11)
    JSON.generate({"purpose" => "lease", "issue" => issue, "coordinator_id" => "seed",
                   "host" => host, "pid" => pid, "created_at" => created_at,
                   "lock_id" => lock_id})
  end

  def seed_lock(store, ref, message)
    sha = JSON.parse(store.route(["gh", "api", "repos/o/r/git/commits",
      "-f", "tree=#{SebasAgents::RefLock::EMPTY_TREE_SHA}", "-f", "message=#{message}"]))["sha"]
    store.route(["gh", "api", "repos/o/r/git/refs", "-f", "ref=#{ref}", "-f", "sha=#{sha}"])
  end

  # 确定性死 pid：Windows 的 pid 回收很快，reap 子进程的 pid 可能被无关进程
  # 复用而误判存活；高位 pid（超出本机 pid 范围）恒 ESRCH，稳定判死。
  STALE_PID = 2147483647

  def payload_of(out)
    JSON.parse(out.string)
  end

  # 场景 1：同机持锁进程存活 → 第二实例 exit 2，零写入。
  def test_claim_refused_while_holder_alive
    with_repo do |snap, _dir|
      store = FakeRefGhStore.new
      seed_lock(store, "refs/locks/sebas/lease-11",
        lock_credential(pid: Process.pid, host: Socket.gethostname))
      out = StringIO.new
      status = cli(store, out).run(["claim", "11", "--snapshot", snap, "--apply"])
      assert_equal 2, status
      payload = payload_of(out)
      assert_equal false, payload["ok"]
      assert_equal "held", payload["lock"]
      assert payload["reasons"].to_s.include?("存活")
      assert_equal 0, store.active_lease_count(11)
      assert store.refs.key?("refs/locks/sebas/lease-11"), "锁未被动过"
    end
  end

  # 场景 2：同机残锁（pid 已死）超宽限 → 接管并认领成功，收尾 ref 已删。
  def test_takeover_stale_same_host_lock
    with_repo do |snap, dir|
      store = FakeRefGhStore.new
      stale = lock_credential(pid: STALE_PID, host: Socket.gethostname,
        created_at: (Time.now.utc - 60).iso8601)
      seed_lock(store, "refs/locks/sebas/lease-11", stale)
      out = StringIO.new
      status = cli(store, out).run(["claim", "11", "--snapshot", snap, "--apply"])
      assert_equal 0, status
      payload = payload_of(out)
      assert_equal "claimed", payload["claim"]
      assert_equal JSON.parse(stale)["lock_id"], payload.dig("lock_takeover", "lock_id")
      refute store.refs.key?("refs/locks/sebas/lease-11"), "收尾必须释放锁"
      record = JSON.parse(File.read(File.join(dir, ".sebas-agent", "runs", "11.json"), encoding: "UTF-8"))
      assert_equal "claimed", record["phase"]
    end
  end

  # 场景 3：同机残锁但锁龄未过宽限 → exit 2。
  def test_stale_lock_within_grace_refused
    with_repo do |snap, _dir|
      store = FakeRefGhStore.new
      seed_lock(store, "refs/locks/sebas/lease-11",
        lock_credential(pid: STALE_PID, host: Socket.gethostname))
      out = StringIO.new
      status = cli(store, out).run(["claim", "11", "--snapshot", snap, "--apply"])
      assert_equal 2, status
      assert payload_of(out)["reasons"].to_s.include?("宽限")
    end
  end

  # 场景 4：异机持有者——未过 TTL 拒绝；过 TTL（lock_ttl_minutes: 1）接管。
  def test_foreign_host_lock_ttl_gate
    with_repo do |snap, _dir|
      store = FakeRefGhStore.new
      seed_lock(store, "refs/locks/sebas/lease-11",
        lock_credential(pid: 1, host: "other-machine"))
      out = StringIO.new
      assert_equal 2, cli(store, out).run(["claim", "11", "--snapshot", snap, "--apply"])
      assert payload_of(out)["reasons"].to_s.include?("TTL")
      assert store.refs.key?("refs/locks/sebas/lease-11")
    end

    with_repo(agents_yml: "coordinators:\n  - ShiningRay\nlock_ttl_minutes: 1\n") do |snap, _dir|
      store = FakeRefGhStore.new
      seed_lock(store, "refs/locks/sebas/lease-11",
        lock_credential(pid: 1, host: "other-machine",
          created_at: (Time.now.utc - 120).iso8601))
      out = StringIO.new
      assert_equal 0, cli(store, out).run(["claim", "11", "--snapshot", snap, "--apply"])
      assert payload_of(out)["lock_takeover"]
      refute store.refs.key?("refs/locks/sebas/lease-11")
    end
  end

  # 场景 4b：TTL 配置——缺省 60 分钟、可覆盖、非法值 fail-closed。
  def test_lock_ttl_config
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p(".github")
        gateway_for = lambda do
          runner = Class.new(SebasAgents::CommandRunner).new(dry_run: true)
          SebasAgents::GithubGateway.new(runner, repo: "o/r")
        end
        assert_equal 3600, gateway_for.call.lock_ttl_seconds
        File.write(".github/agents.yml", "lock_ttl_minutes: 120\n", encoding: "UTF-8")
        assert_equal 7200, gateway_for.call.lock_ttl_seconds
        File.write(".github/agents.yml", "lock_ttl_minutes: abc\n", encoding: "UTF-8")
        error = assert_raises(SebasAgents::CommandError) { gateway_for.call.lock_ttl_seconds }
        assert_includes error.message, "lock_ttl_minutes"
      end
    end
  end

  # 场景 5：release 回读不匹配（锁已被接管）→ 不删他人锁并上报；匹配才删。
  def test_release_mismatch_keeps_foreign_lock
    with_repo do |_snap, _dir|
      store = FakeRefGhStore.new
      seed_lock(store, "refs/locks/sebas/lease-11", lock_credential(lock_id: "other-lock"))
      runner = make_fake(store).new(dry_run: false)
      gateway = SebasAgents::GithubGateway.new(runner, repo: "o/r")
      payload = {}
      refute SebasAgents::RefLock.release!(gateway, ref: "refs/locks/sebas/lease-11",
        lock_id: "mine", payload: payload)
      assert payload["lock_release_mismatch"]
      assert store.refs.key?("refs/locks/sebas/lease-11")

      assert SebasAgents::RefLock.release!(gateway, ref: "refs/locks/sebas/lease-11",
        lock_id: "other-lock", payload: payload)
      refute store.refs.key?("refs/locks/sebas/lease-11")
    end
  end

  # 场景 6：目标卡已 status=In progress 且无租约评论 → refused，不重复开工。
  # 活状态复查读的是远端（假 gh 的 status），不是快照——两处都置为 In progress。
  def test_claim_refused_when_card_already_in_progress
    with_repo do |_snap, _dir|
      data = snapshot(issues: [docs_issue(11, status: "In progress")],
        milestones: [milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)])
      snap = File.join(Dir.pwd, "snapshot.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      store = FakeRefGhStore.new
      store.route(["gh", "api", "-X", "PATCH", "repos/o/r/issues/11", "-f", "status=In progress"])
      out = StringIO.new
      status = cli(store, out).run(["claim", "11", "--snapshot", snap, "--apply"])
      assert_equal 1, status
      payload = payload_of(out)
      assert_equal "refused", payload["claim"]
      assert payload["reasons"].to_s.include?("In progress")
      assert_equal 0, store.active_lease_count(11)
    end
  end

  # 场景 7：真双线程争同一把锁——恰一个 acquired，一个 held（服务端 CAS）。
  def test_concurrent_acquire_single_winner
    with_repo do |_snap, _dir|
      store = FakeRefGhStore.new
      runner = make_fake(store)
      gateway_for = lambda { SebasAgents::GithubGateway.new(runner.new(dry_run: false), repo: "o/r") }
      results = []
      barrier = Queue.new
      threads = 2.times.map do
        Thread.new do
          barrier << :ready
          result = SebasAgents::RefLock.acquire!(gateway_for.call,
            ref: "refs/locks/sebas/lease-11", purpose: "lease", issue: 11)
          results << result
        end
      end
      2.times { barrier.pop }
      threads.each(&:join)

      assert_equal 2, results.length
      assert_equal 1, results.count(&:acquired?), "恰一个拿到锁"
      assert_equal 1, results.count(&:held?), "另一个按 held 退出"
      assert_equal 1, store.refs.size
    end
  end

  # 场景 8：mark-review 的状态迁移写段受同一把逐卡锁保护（正常路径不受影响）。
  def test_mark_review_gated_by_lease_lock
    pr = {"number" => 9, "state" => "OPEN", "head_ref_name" => "feat/11",
          "base_ref_name" => "main", "head_sha" => "abc123", "merged" => false,
          "closing_issues" => [11], "checks" => [], "review_threads" => []}
    with_repo do |_snap, _dir|
      data = snapshot(issues: [docs_issue(11, status: "In progress")],
        milestones: [milestone(number: 1, order: "4x", track: "parallel", open_issues: 1)],
        pull_requests: [pr])
      snap = File.join(Dir.pwd, "snapshot.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      store = FakeRefGhStore.new
      seed_lock(store, "refs/locks/sebas/lease-11",
        lock_credential(pid: Process.pid, host: Socket.gethostname))
      out = StringIO.new
      assert_equal 2, cli(store, out).run(["mark-review", "11", "--snapshot", snap, "--apply"])
      assert_equal "held", payload_of(out)["lock"]

      store2 = FakeRefGhStore.new
      out2 = StringIO.new
      assert_equal 0, cli(store2, out2).run(["mark-review", "11", "--snapshot", snap, "--apply"])
      assert payload_of(out2)["status_written"]
      refute store2.refs.key?("refs/locks/sebas/lease-11"), "正常路径收尾释放锁"
    end
  end
end
