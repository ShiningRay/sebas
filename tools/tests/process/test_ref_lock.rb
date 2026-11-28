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
  attr_accessor :pull_states, :states

  def initialize
    @mutex = Mutex.new
    @comments = []
    @labels = Hash.new { |hash, key| hash[key] = [] }
    @statuses = {}
    @states = Hash.new("open")   # issue 编号 => open/closed
    @pull_states = Hash.new("open")
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
    # GET git/matching-refs/<prefix>：路径参数不含 refs/（官方口径），ref 名
    # 带完整 refs/ 前缀返回；带 refs%2F 的查询直接拒绝（#307 review 整改）。
    if argv[0] == "gh" && argv[1] == "api" &&
       (m = argv[2].to_s.match(%r{repos/o/r/git/matching-refs/(\S+)\z}))
      path = m[1]
      if path.start_with?("refs%2F")
        raise SebasAgents::CommandError.new(
          "stub: matching-refs 查询路径不得带 refs%2F 前缀（#{path}）", command: argv
        )
      end
      prefix = "refs/#{path.gsub('%2F', '/')}"
      rows = @refs.select { |name, _| name.start_with?(prefix) }
                  .map { |name, sha| {"ref" => name, "object" => {"sha" => sha}} }
      return JSON.generate(rows)
    end
    # DELETE git/refs/<ref>：路径不含 refs%（真实口径），带前缀直接拒绝。
    if argv[0] == "gh" && argv[1] == "api" && argv[2] == "-X" && argv[3] == "DELETE" &&
       (m = argv[4].to_s.match(%r{repos/o/r/git/refs/(\S+)\z}))
      if m[1].start_with?("refs%2F")
        raise SebasAgents::CommandError.new(
          "stub: DELETE 路径不得带 refs%2F 前缀（#{m[1]}）", command: argv
        )
      end
      # 真实 API 按「path 段 + refs/ 前缀」定位 ref：删的是完整名 refs/<path>。
      @refs.delete("refs/#{m[1].gsub('%2F', '/')}")
      return "{}"
    end
    # 读单 PR（mark-review 锁内复查 pull_state）
    if (m = joined.match(%r{repos/o/r/pulls/(\d+)\z}))
      return JSON.generate({"state" => @pull_states[Regexp.last_match(1).to_i] || "open"})
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
    # 读单卡（label_present? / status_of / issue_state）
    if (m = joined.match(%r{repos/o/r/issues/(\d+)\z}))
      number = Regexp.last_match(1).to_i
      return JSON.generate({
        "labels" => @labels[number].map { |name| {"name" => name} },
        "status" => {"name" => @statuses[number].to_s},
        "state" => @states[number] || "open"
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

  # 双向屏障（#307 二轮 review）：N 个线程都完成各自的初始读取后才同时放行。
  # `barrier << :ready` 只发通知不阻塞，「A 全部做完 B 才开始」不是并发。
  def run_two_way_barrier(count, &block)
    arrive = Queue.new
    go = Queue.new
    threads = count.times.map do
      Thread.new do
        arrive << :ready
        go.pop
        block.call
      end
    end
    count.times { arrive.pop }
    count.times { go << :go }
    threads.each(&:join)
  end

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
      run_two_way_barrier(2) do
        results << SebasAgents::RefLock.acquire!(gateway_for.call,
          ref: "refs/locks/sebas/lease-11", purpose: "lease", issue: 11)
      end

      assert_equal 2, results.length
      assert_equal 1, results.count(&:acquired?), "恰一个拿到锁"
      assert_equal 1, results.count(&:held?), "另一个按 held 退出"
      assert_equal 1, store.refs.size
    end
  end

  # 直连 RefLock 的测试共用夹具：注入带 ref 路由的 gateway。
  def gateway_over(store)
    runner = make_fake(store)
    SebasAgents::GithubGateway.new(runner.new(dry_run: false), repo: "o/r")
  end

  # 场景 9：同机存活 pid 在 TTL 两侧——TTL 内视为真持有者（不重试）；
  # 超 TTL 按 pid 复用护栏接管（锁是命令级的，超 TTL 的「存活 pid」几乎
  # 不可能是当年持有者）。
  def test_same_host_alive_pid_ttl_boundary
    with_repo do |_snap, _dir|
      store = FakeRefGhStore.new
      # 异 pid 存活（真实外部进程）：TTL 内视为真持有者。
      other = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
      begin
        seed_lock(store, "refs/locks/sebas/lease-11",
          lock_credential(pid: other, host: Socket.gethostname,
            created_at: (Time.now.utc - 10).iso8601))
        held = SebasAgents::RefLock.acquire!(gateway_over(store),
          ref: "refs/locks/sebas/lease-11", purpose: "lease", issue: 11, ttl_seconds: 60)
        assert held.held?
        assert held.reasons.join.include?("存活")
        assert_equal 1, store.refs.size, "TTL 内不得动锁"
      ensure
        Process.kill("KILL", other) rescue nil
        Process.wait(other) rescue nil
      end

      store2 = FakeRefGhStore.new
      # pid 复用护栏针对「异 pid 存活」：本进程重入走幂等路径（own_process_
      # credential?），这里用一个真实存活的外部进程模拟被回收的旧 pid。
      recycled = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
      begin
        seed_lock(store2, "refs/locks/sebas/lease-11",
          lock_credential(pid: recycled, host: Socket.gethostname,
            created_at: (Time.now.utc - 120).iso8601))
        taken = SebasAgents::RefLock.acquire!(gateway_over(store2),
          ref: "refs/locks/sebas/lease-11", purpose: "lease", issue: 11, ttl_seconds: 60)
        assert taken.acquired?, "超 TTL 的同机异 pid 存活按 pid 复用护栏接管：#{taken.reasons.inspect}"
        refute_equal "seed-lock", taken.credential["lock_id"], "接管后是新凭据"
        assert_equal 1, store2.refs.size, "声明锁收尾不得残留"
      ensure
        Process.kill("KILL", recycled) rescue nil
        Process.wait(recycled) rescue nil
      end
    end
  end

  # 场景 10：凭据不可解析（fail-closed）——拒绝获取，原 ref 原样保留。
  def test_unreadable_credential_refused
    with_repo do |_snap, _dir|
      store = FakeRefGhStore.new
      sha = JSON.parse(store.route(["gh", "api", "repos/o/r/git/commits",
        "-f", "tree=#{SebasAgents::RefLock::EMPTY_TREE_SHA}", "-f", "message=not-a-json"]))["sha"]
      store.route(["gh", "api", "repos/o/r/git/refs",
        "-f", "ref=refs/locks/sebas/lease-11", "-f", "sha=#{sha}"])

      held = SebasAgents::RefLock.acquire!(gateway_over(store),
        ref: "refs/locks/sebas/lease-11", purpose: "lease", issue: 11)
      assert held.held?
      assert held.reasons.join.include?("不可解析")
      assert_equal sha, store.refs["refs/locks/sebas/lease-11"], "原锁不得被动过"
    end
  end

  # 场景 11：matching-refs 是前缀匹配——lease-306 与 lease-3060 必须按完整
  # ref 名精确区分，不得互相误判（#307 review 整改）。
  def test_prefix_collision_resolved_by_exact_ref_name
    with_repo do |_snap, _dir|
      store = FakeRefGhStore.new
      seed_lock(store, "refs/locks/sebas/lease-3060",
        lock_credential(pid: 1, host: "other-machine", lock_id: "bigger-issue"))

      acquired = SebasAgents::RefLock.acquire!(gateway_over(store),
        ref: "refs/locks/sebas/lease-306", purpose: "lease", issue: 306, ttl_seconds: 3600)
      assert acquired.acquired?, "lease-306 与 lease-3060 不同名，后者在也不得阻塞前者"
      assert_equal 2, store.refs.size
      neighbor = JSON.parse(store.route(["gh", "api", "repos/o/r/git/commits/#{store.refs["refs/locks/sebas/lease-3060"]}"]))
      assert_equal "bigger-issue", JSON.parse(neighbor["message"])["lock_id"], "邻卡锁不得被动过"
    end
  end

  # 场景 12：真双线程并发接管同一把残锁——声明锁 CAS 保证恰一个接管成功，
  # 另一个 held；不出现双双 acquired（#307 review 整改的协议验证）。
  # 双向屏障（#307 二轮 review）：两线程都完成初始读取准备后才同时放行，
  # 避免「A 全部完成 B 才开始」的假并发。
  def test_concurrent_takeover_single_winner
    with_repo do |_snap, _dir|
      store = FakeRefGhStore.new
      seed_lock(store, "refs/locks/sebas/lease-11",
        lock_credential(pid: STALE_PID, host: Socket.gethostname,
          created_at: (Time.now.utc - 60).iso8601))
      results = []
      run_two_way_barrier(2) do |slot, wait_others, release_others|
        results << SebasAgents::RefLock.acquire!(gateway_over(store),
          ref: "refs/locks/sebas/lease-11", purpose: "lease", issue: 11, ttl_seconds: 3600)
      end

      assert_equal 1, results.count(&:acquired?), "并发接管恰一个成功"
      assert_equal 1, results.count(&:held?), "另一个按 held 退出"
      assert_equal 1, store.refs.size, "主锁恰一条，声明锁不残留"
    end
  end

  # 场景 13：普通争锁测试同样用双向屏障（#307 二轮 review）。
  def test_concurrent_acquire_two_way_barrier
    with_repo do |_snap, _dir|
      store = FakeRefGhStore.new
      results = []
      run_two_way_barrier(2) do |_slot, _wait, _release|
        results << SebasAgents::RefLock.acquire!(gateway_over(store),
          ref: "refs/locks/sebas/lease-11", purpose: "lease", issue: 11)
      end

      assert_equal 1, results.count(&:acquired?)
      assert_equal 1, results.count(&:held?)
      assert_equal 1, store.refs.size
    end
  end

  # 场景 14：创建结果不确定（超时重放撞上自己的创建）——422 后回读 lock_id
  # 是本次凭据 → :ok 视为已持有（#307 二轮 review）。等价终态：服务端已有
  # 同名 ref，凭据与本次待建凭据 lock_id 一致/不一致两种分支。
  def test_duplicate_with_own_lock_id_recognized_as_acquired
    with_repo do |_snap, _dir|
      store = FakeRefGhStore.new
      fixed = {"purpose" => "lease", "issue" => 11, "coordinator_id" => "fixed",
               "host" => Socket.gethostname, "pid" => Process.pid,
               "created_at" => Time.now.utc.iso8601, "lock_id" => "fixed-uuid"}
      seed_lock(store, "refs/locks/sebas/lease-11", JSON.generate(fixed))
      gateway = gateway_over(store)

      assert_equal :ok, SebasAgents::RefLock.create_lock(gateway, "refs/locks/sebas/lease-11", fixed.dup),
                   "422 但持有者 lock_id 是自己 → :ok（超时重放的等价终态）"

      stranger = fixed.merge("lock_id" => "other-uuid")
      assert_equal :duplicate, SebasAgents::RefLock.create_lock(gateway, "refs/locks/sebas/lease-11", stranger),
                   "422 且持有者 lock_id 不是自己 → :duplicate"
    end
  end

  # 场景 15：残声明接管与活声明保护（#307 二轮 review 的交错语义，顺序化）。
  # 先到者建立的新声明（pid 活、age 小）对后到者必须 held 且原样保留。
  def test_stale_claim_takeover_and_live_claim_protection
    with_repo do |_snap, _dir|
      store = FakeRefGhStore.new
      claim_ref = "refs/locks/sebas-claims/lease-11"
      seed_lock(store, claim_ref,
        lock_credential(pid: STALE_PID, host: Socket.gethostname,
          created_at: (Time.now.utc - 120).iso8601, lock_id: "stale-claim"))

      first, held1 = SebasAgents::RefLock.with_claim_exclusivity(
        gateway_over(store), claim_ref, issue: 11, ttl_seconds: 3600, grace_seconds: 30)
      assert first, "残声明（死 pid 超宽限）应被接管"
      assert held1.nil?

      second, held2 = SebasAgents::RefLock.with_claim_exclusivity(
        gateway_over(store), claim_ref, issue: 11, ttl_seconds: 3600, grace_seconds: 30)
      assert second.nil?, "活声明（本进程刚建）不得被后到者接管"
      assert held2
      current = JSON.parse(store.route(["gh", "api", "repos/o/r/git/commits/#{store.refs[claim_ref]}"]))
      assert_equal first["lock_id"], JSON.parse(current["message"])["lock_id"], "先到者的声明原样保留"
    end
  end

  # 场景 16：mark-review 锁内复核——快照是锁前取的，卡已关闭时拒绝迁移。
  def test_mark_review_lock_time_recheck
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
      store.states[11] = "closed" # 远端在锁前快照后被合并收口
      out = StringIO.new
      assert_equal 1, cli(store, out).run(["mark-review", "11", "--snapshot", snap, "--apply"])
      payload = payload_of(out)
      assert payload["reasons"].to_s.include?("锁内复核")
      refute payload["status_written"]
    end
  end

  # 场景 17：unclaim --apply 只输出一份 JSON 且退出码与之一致（#307 二轮
  # review：修复前 apply 分支输出后落入非 apply 分支，双输出且恒 EXIT_OK）。
  def test_unclaim_apply_single_output
    pr = {"number" => 9, "state" => "MERGED", "merged" => true, "head_ref_name" => "feat/11",
          "base_ref_name" => "main", "head_sha" => "abc123", "closing_issues" => [11],
          "checks" => [], "review_threads" => []}
    with_repo do |_snap, _dir|
      done = docs_issue(11, status: "Done")
      done["state"] = "CLOSED"
      done["state_reason"] = "completed"
      data = snapshot(issues: [done],
        milestones: [milestone(number: 1, order: "4x", track: "parallel", open_issues: 0)],
        pull_requests: [pr])
      snap = File.join(Dir.pwd, "snapshot.json")
      File.write(snap, JSON.generate(data), encoding: "UTF-8")
      store = FakeRefGhStore.new
      out = StringIO.new
      assert_equal 0, cli(store, out).run(["unclaim", "11", "--snapshot", snap, "--apply"])
      payload = JSON.parse(out.string) # 恰一份 JSON：双输出会解析失败
      assert_equal true, payload["ok"]
      assert_equal "released", payload["status"]
    end
  end

  # ---- repo_pending_evidence! 直测（#307 四轮 review）----

  # 直测夹具：Model::Snapshot + 一张已合并 PR（from_hash 收原始 Hash）。
  def fresh_snapshot(issues, closing_issues)
    SebasAgents::Model::Snapshot.from_hash(
      "repo" => "o/r", "main_sha" => "deadbeef", "milestones" => [], "issues" => issues,
      "pull_requests" => [{"number" => 9, "state" => "MERGED", "head_sha" => "abc",
                           "closing_issues" => closing_issues}],
      "maintainers" => [], "source_authors" => {}, "gates" => {},
      "externals" => {}, "trusted_bots" => [], "source_bodies" => {}
    )
  end

  def evidence_body(subject:, merged:)
    "```json evidence\n#{JSON.pretty_generate({"schema" => 1, "subject" => subject, "status" => "accepted",
      "source" => "maintainer", "source_ref" => "u", "pr" => 9, "merge_commit" => "abc",
      "checks" => nil, "gate_status" => nil, "evidence_path" => nil, "untested" => [],
      "ready" => nil, "merged_into_main" => merged})}\n```"
  end

  def plain_issue(number, labels: [], type: "Task")
    {"number" => number, "state" => "CLOSED", "state_reason" => "completed",
     "labels" => labels, "type" => type, "milestone" => nil,
     "body" => "## 说明\n", "blocked_by" => [], "status" => "Done"}
  end

  def test_repo_pending_evidence_branches
    cli = SebasAgents::CLI.new(out: StringIO.new, err: StringIO.new)

    # proposal 卡（标签或 type 命中）排除：登记脚本跳过 proposal，Evidence
    # 永不升级，不得永久阻塞队列。
    proposal_snap = fresh_snapshot([plain_issue(11, labels: ["proposal"])], [11])
    assert_empty cli.send(:repo_pending_evidence!, proposal_snap)

    # 普通卡未升级（merged_into_main != true）保留。
    plain = plain_issue(11)
    plain["body"] = evidence_body(subject: "issue #11", merged: false)
    assert_equal [11], cli.send(:repo_pending_evidence!, fresh_snapshot([plain], [11]))

    # 已升级（merged_into_main == true）排除。
    upgraded = plain_issue(11)
    upgraded["body"] = evidence_body(subject: "issue #11", merged: true)
    assert_empty cli.send(:repo_pending_evidence!, fresh_snapshot([upgraded], [11]))

    # 缺卡编号保留（fail-closed）：state=all 快照缺卡即引用/数据异常，
    # snap_evidence_merged? 返回 nil（未知按未完成），不静默放行。
    assert_equal [99], cli.send(:repo_pending_evidence!, fresh_snapshot([], [99]))
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
      # 锁内复核读的是远端（假 gh）：把 In progress 同步进桩。
      store2.route(["gh", "api", "-X", "PATCH", "repos/o/r/issues/11", "-f", "status=In progress"])
      out2 = StringIO.new
      assert_equal 0, cli(store2, out2).run(["mark-review", "11", "--snapshot", snap, "--apply"])
      assert payload_of(out2)["status_written"]
      refute store2.refs.key?("refs/locks/sebas/lease-11"), "正常路径收尾释放锁"
    end
  end
end
