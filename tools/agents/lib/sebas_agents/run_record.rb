# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require "socket"

module SebasAgents
  # 本地运行记录：worktree 之外，原子写入，绝不保存凭据。
  #
  # v2（M4x-Parallel-WP2，#220；Proposal §5.1 + 续篇 §7 Q10=B）：
  # - 路径迁移 `.sebas-agent/run.json` → `.sebas-agent/runs/<issue>.json`，
  #   搬迁并双读一个版本：启动时自动搬迁非活动记录；活动中的 v1 记录
  #   （claiming/claimed/pr_open/merging/paused）缺 v2 字段，须人工确认，
  #   自动搬迁直接 invalid_plan（fail-closed）。
  # - `runs/` 里出现 schema 不是 2 的记录即 invalid_plan。
  # - 迁移期容量固定为 1（plan/next 的容量常量本就是 1，无需改判）。
  # - 新增字段：worker_id / coordinator_id / lease_id / scope / host /
  #   claimed_at / last_heartbeat_at。
  class RunRecord
    DEFAULT_PATH = File.join(".sebas-agent", "run.json")
    RUNS_DIR = File.join(".sebas-agent", "runs")
    SCHEMA = 2
    LEGACY_SCHEMA = 1
    FIELDS = %w[
      issue branch worktree pr base_sha phase attempts status_written label_written
      worker_id coordinator_id lease_id scope host claimed_at last_heartbeat_at pid
    ].freeze
    # 活动 phase（续篇 §7）：这些记录代表持有中的租约，缺 v2 字段不能自动搬。
    ACTIVE_PHASES = %w[claiming claimed pr_open merging paused].freeze

    attr_reader :path, :issue

    # path 显式给出时按调用方路径读写（测试与离线快照用）；
    # 否则按 issue 走 v2 per-issue 路径，issue 未知时回落 v1 路径（双读窗口）。
    def initialize(path: nil, issue: nil)
      @issue = issue
      @path = path || self.class.per_issue_path(issue)
      @legacy_path = DEFAULT_PATH
    end

    def self.per_issue_path(issue)
      File.join(RUNS_DIR, "#{issue}.json")
    end

    # 活动记录清单（CR-12）：runs/ 下 phase ∈ ACTIVE_PHASES 的记录。
    # schema 非 2 → invalid_plan；多份活动记录是否合法由调用方按
    # 迁移窗口/试点容量判定（迁移期容量 1；试点 docs 对容量 2）。
    def self.active_records(runs_dir = RUNS_DIR)
      return [] unless Dir.exist?(runs_dir)

      Dir.children(runs_dir).grep(/\.json\z/).filter_map do |file|
        path = File.join(runs_dir, file)
        data = JSON.parse(File.read(path, encoding: "UTF-8"))
        if data["schema"] != SCHEMA
          raise InvalidPlan, "runs/ 下的运行记录 schema 必须是 #{SCHEMA}：#{path}"
        end

        data if ACTIVE_PHASES.include?(data["phase"])
      end.sort_by! { |data| data["issue"].to_i }
    rescue JSON::ParserError => e
      raise InvalidPlan, "运行记录不是合法 JSON（#{runs_dir}）：#{e.message}"
    end

    # 启动搬迁（Q10=B）：v1 路径存在 && v2 同卡路径不存在时搬迁。
    # 非活动记录自动搬（补 schema=2 与 v2 缺省字段）；活动记录 fail-closed
    # 要求人工确认。搬完删旧路径。v2 路径已存在时不覆盖（不吞更新）。
    # runs_dir 可注入（测试用）；生产缺省走 CWD 相对的 RUNS_DIR。
    def self.migrate_legacy!(legacy_path = DEFAULT_PATH, runs_dir: RUNS_DIR)
      return false unless File.exist?(legacy_path)

      data = JSON.parse(File.read(legacy_path, encoding: "UTF-8"))
      raise InvalidPlan, "v1 运行记录不是合法 JSON：#{legacy_path}" if data.nil?
      if ![LEGACY_SCHEMA, SCHEMA].include?(data["schema"])
        raise InvalidPlan, "运行记录 schema 不支持（#{data["schema"].inspect}）：#{legacy_path}"
      end

      # aborted 是认领未确认的异常态（续篇 F3/F4）：须先对账（status_written、
      # 凭据归属），不得随迁移静默解除容量钳制——故迁移守卫在 ACTIVE_PHASES
      # 之外单列 aborted；只有 released 等静默态自动搬迁。不改全局
      # ACTIVE_PHASES，避免波及 active_records 的路由口径。
      migration_blocking_phases = ACTIVE_PHASES + %w[aborted]
      issue = data["issue"]
      target = issue ? File.join(runs_dir, "#{issue}.json") : nil
      if target.nil? || File.exist?(target)
        # 无 issue 的孤儿记录或同卡 v2 已在：活动态不吞更新，静默态保留待人工。
        if migration_blocking_phases.include?(data["phase"])
          raise InvalidPlan, "v1 活动运行记录（phase=#{data["phase"].inspect}）与既有 v2 记录并存，需人工确认后才能搬迁：#{legacy_path}"
        end
        return false
      end

      if migration_blocking_phases.include?(data["phase"])
        raise InvalidPlan,
          "v1 活动运行记录（phase=#{data["phase"].inspect}）缺 base_sha/lease_id/scope 等 v2 字段，" \
          "须人工确认归属后才能搬迁：请核对远端认领并手工搬至 #{target}（或删除记录重新认领）"
      end

      migrated = data.slice(*FIELDS)
        .merge("schema" => SCHEMA)
        .merge(%w[worker_id coordinator_id lease_id scope host claimed_at last_heartbeat_at]
          .filter_map { |field| [field, data[field]] unless data.key?(field) }.to_h)
      FileUtils.mkdir_p(File.dirname(target))
      temp = "#{target}.tmp"
      File.write(temp, JSON.pretty_generate(migrated), encoding: "UTF-8")
      File.rename(temp, target)
      FileUtils.rm_f(legacy_path)
      true
    rescue JSON::ParserError => e
      raise InvalidPlan, "v1 运行记录不是合法 JSON（#{legacy_path}）：#{e.message}"
    end

    # 双读（迁移窗口）：per-issue（runs/）路径强制 schema 2；显式路径与 v1
    # 遗留路径容忍 schema 1（迁移窗口内的旧记录原样可读，写入恒为 v2）。
    # 未知 schema（如 99）一律拒绝——不把不支持的记录格式静默当旧版读。
    def load
      if File.exist?(@path)
        data = JSON.parse(File.read(@path, encoding: "UTF-8"))
        if File.dirname(@path) == RUNS_DIR && data["schema"] != SCHEMA
          raise InvalidPlan, "runs/ 下的运行记录 schema 必须是 #{SCHEMA}（got #{data["schema"].inspect}）：#{path}"
        end
        unless [LEGACY_SCHEMA, SCHEMA].include?(data["schema"])
          raise InvalidPlan, "运行记录 schema 不支持（#{data["schema"].inspect}）：#{path}"
        end

        return data
      end
      return nil unless File.exist?(@legacy_path)

      data = JSON.parse(File.read(@legacy_path, encoding: "UTF-8"))
      unless [LEGACY_SCHEMA, SCHEMA].include?(data["schema"])
        raise InvalidPlan, "运行记录 schema 不支持（#{data["schema"].inspect}）：#{@legacy_path}"
      end

      data
    rescue JSON::ParserError => e
      raise InvalidPlan, "运行记录不是合法 JSON：#{e.message}"
    end

    # 写入恒为 schema 2：路径显式指定或 issue 可知时落 per-issue 路径。
    def save(record)
      target = @path
      payload = record.slice(*FIELDS).merge("schema" => SCHEMA, "updated_at" => Time.now.utc.iso8601)
      FileUtils.mkdir_p(File.dirname(target))
      temp = "#{target}.tmp"
      File.write(temp, JSON.pretty_generate(payload), encoding: "UTF-8")
      File.rename(temp, target)
      payload
    end

    def clear
      FileUtils.rm_f(@path)
    end

    # 心跳（§F5）：worker 存活证明。只写本卡记录，不动其他租约。
    #
    # 读—改—写必须在**跨进程**锁内完成：原子 rename 只保证「不写坏文件」，
    # 挡不住两个进程各自读到旧快照再覆盖（后写的会吞掉先写的字段）。
    # 用独占创建的锁文件（与 coordinator 锁同一套路），拿不到锁就放弃本次
    # 心跳——心跳丢一次不影响正确性，覆盖别人的写入才会。
    #
    # 同时记 `pid`：写心跳的就是 worker 自己，所以它的 pid 正是「worker 是否
    # 还在」的判据。`host` 保持认领时的值不覆盖——换机写心跳不应让租约看起来
    # 属于新机器（F6 的归属判定按 host 走）。
    def heartbeat!(now: Time.now.utc)
      with_record_lock(@path) do
        data = load
        break nil if data.nil? || data.empty?

        save(data.merge("last_heartbeat_at" => now.iso8601, "pid" => Process.pid))
      end
    end

    # worker 是否还活着（§F5）。三级证据，缺一即「不可判定」：
    #   1. 记录里有 pid，且
    #   2. 记录里的 host 就是本机（跨机 pid 无意义），且
    #   3. `kill(0, pid)` 不抛 ESRCH。
    # 返回 true（活着）/ false（已消失）/ nil（判不了：缺 pid、跨机、pid 非法）。
    # 调用方必须把 nil 与 false 区分开：nil 不能当成「可以接管」。
    def worker_alive?
      data = load
      return nil if data.nil? || data.empty?

      pid = data["pid"]
      # pid 可能是整数（save 写的就是 Integer）或字符串（外部手改）。
      # `Integer(int, 10)` 会抛 ArgumentError——那会被下面的 rescue 吞成 nil，
      # 于是整数 pid 永远判不了。这里先归一成整数再判。
      pid_int = case pid
                when Integer then pid.positive? ? pid : nil
                when String then pid.match?(/\A\d+\z/) ? pid.to_i : nil
                end
      return nil if pid_int.nil?

      recorded_host = data["host"].to_s
      return nil if recorded_host.empty? || recorded_host != Socket.gethostname

      Process.kill(0, pid_int)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      # 进程存在但无权发信号：活着。
      true
    end

    # 心跳是否过期（§F5）。
    # - 缺字段（key 不存在）→ 不判过期：老记录没有该字段，否则升级当次
    #   每张在途卡都被判死。仅这一种情形保留兼容。
    # - 空字符串 / 非法时间戳 → 过期（fail-closed）：字段存在却读不出来，
    #   说明记录已被写坏，按过期交恢复路径核对。
    # 判据只有时间——pid 在跨机/容器场景不可靠，不作为唯一依据。
    def heartbeat_expired?(ttl_seconds, now: Time.now.utc)
      data = load
      return false if data.nil? || data.empty?
      return false unless data.key?("last_heartbeat_at")

      stamp = data["last_heartbeat_at"]
      return true if stamp.nil? || stamp.to_s.empty?

      Time.iso8601(stamp.to_s) < now - ttl_seconds
    rescue ArgumentError
      true
    end

    private

    # 跨进程独占锁：锁文件用 O_CREAT|O_EXCL 创建，内容写 pid 便于排查。
    #
    # 三种结局：
    #   - 拿到锁 → 执行 → 释放
    #   - 有锁且持有者进程仍活着 → 跳过本次心跳（不等待、不抢锁）
    #   - 有锁但 pid 已不存在（崩溃残留）→ 接管：删掉再创建，只重试一次
    #
    # 残留锁必须能被接管，否则一次崩溃就让这张卡的心跳永久失效，F5 判据
    # 变成「永远不过期」，恰好是最危险的反向失效。接管只看 pid 是否存活，
    # 因此它防的是「同机进程已退出」，不防跨机同名 pid——那由 host 字段判。
    def with_record_lock(path)
      lock = "#{path}.lock"
      FileUtils.mkdir_p(File.dirname(lock))
      handle = acquire_lock(lock)
      return nil unless handle

      begin
        handle.write(Process.pid.to_s)
        handle.close
        yield
      ensure
        # 正常路径与异常路径都清锁：写 pid / close 失败会留下半成品锁，
        # 那会挡住后续所有心跳。
        FileUtils.rm_f(lock)
      end
    end

    # 返回已打开的锁句柄；拿不到（活跃持有者）返回 nil。
    # 写 pid / 关闭失败时自己删锁再抛：否则半成品锁会挡住后续所有心跳。
    def acquire_lock(lock)
      handle = File.open(lock, File::CREAT | File::EXCL | File::WRONLY)
      handle
    rescue Errno::EEXIST
      return nil unless stale_lock?(lock)

      FileUtils.rm_f(lock)
      begin
        File.open(lock, File::CREAT | File::EXCL | File::WRONLY)
      rescue Errno::EEXIST
        nil
      end
    end

    # 残留判定：读得到 pid 且该进程已不存在 → 残留；其余一律按活跃。
    #
    # 只有 `Errno::ESRCH`（进程不存在）才是残留证据。`EPERM` 表示进程存在但
    # 无权限发信号——**那是活跃持有者**，删它的锁会破坏互斥，必须按活跃处理。
    # 读不到 pid、pid 非法、文件已消失同样按活跃：锁刚创建还没写 pid 的窗口
    # 里删它会伤到别人。
    def stale_lock?(lock)
      pid = File.read(lock, encoding: "UTF-8").strip
      return false if pid.empty?

      Process.kill(0, Integer(pid, 10))
      false
    rescue Errno::ESRCH
      true
    rescue ArgumentError, Errno::ENOENT, Errno::EACCES, Errno::EPERM
      false
    end

    def read_v2(path)
      data = JSON.parse(File.read(path, encoding: "UTF-8"))
      if data["schema"] != SCHEMA
        raise InvalidPlan, "运行记录 schema 必须是 #{SCHEMA}（got #{data["schema"].inspect}）：#{path}"
      end

      data
    rescue JSON::ParserError => e
      raise InvalidPlan, "运行记录不是合法 JSON：#{e.message}"
    end
  end
end
