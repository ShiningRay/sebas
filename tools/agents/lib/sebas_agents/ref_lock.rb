# frozen_string_literal: true

require "json"
require "securerandom"
require "socket"
require "time"

module SebasAgents
  # 跨机原子互斥锁（#306）：以 GitHub git-ref 创建为 CAS 原语。
  #
  # 机制：并发 `POST /repos/*/git/refs` 同名 ref，服务端恰一个 201、另一个
  # 422 "Reference already exists"——跨机的互斥仲裁者是 GitHub 本身，不依赖
  # 本地锁（本地锁只覆盖同机同目录，两台机器各持各的锁互不知情）。
  # 锁凭据（JSON）存放在 ref 指向 commit 的 message 里，可回读判定归属。
  #
  # 时长分层（implementer-loop §5 / 续篇 §4 口径）：
  # - 锁是**命令级**的：只包住 claim/unclaim/mark-review/queue 的写段
  #   （几次 gh API 调用，秒级）。任务开工后锁即释放，干活期间不持锁。
  # - 任务级所有权仍由租约评论（Lease）承担：state=active 覆盖整个任务期，
  #   别的机器认领同卡会先拿到锁、再被租约预检拒绝。F9 语义不动。
  # - TTL 只决定「持锁进程写命令中途崩溃留下的残锁，多久后允许异机接管」：
  #   缺省 60 分钟（lock_ttl_minutes），宁大勿小——调大不削弱互斥，
  #   只拉长残锁等待；残锁按逐卡 ref 命名，只阻塞对应那张卡的写命令。
  module RefLock
    LOCK_PREFIX = "refs/locks/sebas"
    # git 空树的稳定 SHA（对象恒存在，无需先建 tree）。
    EMPTY_TREE_SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    # 同机残锁接管宽限：pid 判死后再等一小段，避免 fork 竞态误接管。
    GRACE_SECONDS = 30
    DEFAULT_TTL_MINUTES = 60

    CREDENTIAL_FIELDS = %w[purpose issue coordinator_id host pid created_at lock_id].freeze

    # acquire!/release! 的结果：status ∈ :acquired / :held。
    # :acquired 且 previous 非空 = 接管了残锁（previous 是原持有者凭据）；
    # :held 时 holder 是持有者凭据（或 nil=凭据不可解析），reasons 说明证据。
    Outcome = Data.define(:status, :credential, :holder, :reasons, :previous) do
      def acquired?
        status == :acquired
      end

      def held?
        status == :held
      end
    end

    module_function

    # 逐卡锁：claim / unclaim / mark-review 用，不同卡的写命令互不阻塞。
    def lease_ref(issue)
      "#{LOCK_PREFIX}/lease-#{issue}"
    end

    # 全局锁：queue 合并链（§7.2 合并串行）。
    def merge_ref
      "#{LOCK_PREFIX}/merge"
    end

    # 尝试拿锁。网络/权限类 CommandError 不在此翻译，直接上抛——
    # 调用方按「写入失败」路径处理，不得把「读不到」当成「没有锁」。
    def acquire!(gateway, ref:, purpose:, issue: nil, ttl_seconds: DEFAULT_TTL_MINUTES * 60,
                 grace_seconds: GRACE_SECONDS)
      holder = read_holder(gateway, ref)
      if holder
        verdict = judge(holder, ref: ref, ttl_seconds: ttl_seconds, grace_seconds: grace_seconds)
        return verdict if verdict.held?

        # 接管：删旧建新。删与建之间另一台机器也在接管时，重建会撞 422——
        # 那就按 held 退出，归属由「谁先重建成功」决定，互斥不破。
        gateway.delete_lock_ref(ref, allow_write: true)
      end

      credential = new_credential(purpose: purpose, issue: issue)
      created = create_lock(gateway, ref, credential)
      if created == :duplicate
        rival = read_holder(gateway, ref)
        return Outcome.new(status: :held, credential: nil, holder: rival,
          reasons: ["锁 #{ref} 在接管重建时被并发获取，归属以服务端 CAS 结果为准",
                    holder_summary(rival)], previous: nil)
      end
      Outcome.new(status: :acquired, credential: credential, holder: nil, reasons: [],
        previous: holder || nil)
    end

    # 释放锁：先回读凭据，确认还是自己的才删。已被接管（lock_id 不匹配）
    # 或凭据不可解析 → 不删，通过 payload 上报，fail-closed。
    # dry-run 演练没有写动作（与 acquire 侧口径一致），直接按已释放放行。
    def release!(gateway, ref:, lock_id:, payload: nil)
      return true if gateway.respond_to?(:dry_run?) && gateway.dry_run?

      holder = read_holder(gateway, ref)
      return true if holder.nil?

      if holder == :unreadable || holder["lock_id"] != lock_id
        if payload
          payload["lock_release_mismatch"] =
            "锁 #{ref} 已不是本次获取者持有（#{holder_summary(holder)}），不删除他人锁，需人工核对"
        end
        return false
      end

      gateway.delete_lock_ref(ref, allow_write: true)
      true
    end

    # ---- 判定 ----

    # 持有者判活：:held（含接管证据不足的情形）或 :takeover 占位（此处返回
    # 一个非 held 的 Outcome，由 acquire! 继续接管路径）。
    def judge(holder, ref:, ttl_seconds:, grace_seconds:)
      if holder == :unreadable
        return Outcome.new(status: :held, credential: nil, holder: nil,
          reasons: ["锁 #{ref} 的凭据不可解析（fail-closed），需人工核对"], previous: nil)
      end

      same_host = holder["host"] == Socket.gethostname
      if same_host
        return judge_same_host(holder, ref: ref, ttl_seconds: ttl_seconds,
          grace_seconds: grace_seconds)
      end

      age = lock_age(holder)
      if age.nil?
        return Outcome.new(status: :held, credential: nil, holder: holder,
          reasons: ["锁 #{ref} 异机持有者凭据缺 created_at（fail-closed），需人工核对",
                    holder_summary(holder)], previous: nil)
      end
      if age < ttl_seconds
        return Outcome.new(status: :held, credential: nil, holder: holder,
          reasons: ["锁 #{ref} 由异机持有（#{holder_summary(holder)}），锁龄 #{age.to_i}s 未过 TTL #{ttl_seconds}s，不接管",
                    "跨机无法判定对方进程死活，只能等 TTL 判残锁"], previous: nil)
      end

      # 异机过 TTL：视为持锁进程已崩溃，允许接管。
      Outcome.new(status: :takeover, credential: nil, holder: holder, reasons: [], previous: nil)
    end

    def judge_same_host(holder, ref:, ttl_seconds:, grace_seconds:)
      pid = holder["pid"]
      unless pid.is_a?(Integer) && pid >= 1
        return Outcome.new(status: :held, credential: nil, holder: holder,
          reasons: ["锁 #{ref} 同机持有者凭据 pid 非法（fail-closed），需人工核对",
                    holder_summary(holder)], previous: nil)
      end

      alive = pid_alive?(pid)
      age = lock_age(holder)
      if alive
        # pid 复用护栏（Windows 上 pid 回收很快）：锁龄超过 TTL 的「存活 pid」
        # 几乎不可能是当年那位持有者，按残锁接管——否则一张陈旧锁会被无关
        # 进程顶到永远 held。锁是命令级的（秒级），TTL 内存活视为真持有者。
        if age.nil?
          return Outcome.new(status: :held, credential: nil, holder: holder,
            reasons: ["锁 #{ref} 同机持有者凭据缺 created_at（fail-closed），需人工核对",
                      holder_summary(holder)], previous: nil)
        end
        if age < ttl_seconds
          return Outcome.new(status: :held, credential: nil, holder: holder,
            reasons: ["锁 #{ref} 的持锁进程与本进程同机且存活（pid=#{pid}），不重试"], previous: nil)
        end
        return Outcome.new(status: :takeover, credential: nil, holder: holder, reasons: [], previous: nil)
      end

      if age.nil? || age < grace_seconds
        waited = age.nil? ? "凭据缺 created_at" : "锁龄 #{age.to_i}s 未过宽限 #{grace_seconds}s"
        return Outcome.new(status: :held, credential: nil, holder: holder,
          reasons: ["锁 #{ref} 同机持锁进程已退出（pid=#{pid}），但 #{waited}，接管前先等待"], previous: nil)
      end

      Outcome.new(status: :takeover, credential: nil, holder: holder, reasons: [], previous: nil)
    end

    # 只有 Errno::ESRCH 才判死（口径同 run_record.stale_lock?）：
    # EPERM 是进程存在但无权限发信号，算活跃；其余一律按活跃 fail-closed。
    def pid_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue ArgumentError, Errno::ENOENT, Errno::EACCES, Errno::EPERM
      true
    end

    def lock_age(holder)
      stamp = holder["created_at"]
      return nil unless stamp.is_a?(String) && !stamp.empty?

      Time.now.utc - Time.iso8601(stamp)
    rescue ArgumentError
      nil
    end

    def holder_summary(holder)
      return "凭据不可解析" if holder.nil? || holder == :unreadable

      "coordinator_id=#{holder["coordinator_id"].inspect} host=#{holder["host"].inspect} " \
        "pid=#{holder["pid"].inspect} created_at=#{holder["created_at"].inspect}"
    end

    # ---- 凭据与远端原语 ----

    def new_credential(purpose:, issue:)
      {
        "purpose" => purpose,
        "issue" => issue,
        "coordinator_id" => ENV["SEBAS_COORDINATOR_ID"] || Socket.gethostname,
        "host" => Socket.gethostname,
        "pid" => Process.pid,
        "created_at" => Time.now.utc.iso8601,
        "lock_id" => SecureRandom.uuid
      }
    end

    # 读当前持有者凭据：无 ref → nil；凭据不可解析 → :unreadable。
    # matching-refs 按前缀匹配，精确 ref 名命中即恰一条；多条是不可能状态，
    # fail-closed 上抛而不是猜一条。
    def read_holder(gateway, ref)
      rows = gateway.get_matching_refs(ref)
      unless rows.is_a?(Array)
        raise InvalidPlan, "锁 #{ref} 的 matching-refs 返回非数组：#{rows.inspect[0, 200]}"
      end
      return nil if rows.empty?

      if rows.length > 1
        raise InvalidPlan, "锁 #{ref} 匹配到 #{rows.length} 条 ref（不可能状态）：需人工核对"
      end

      sha = rows.first.dig("object", "sha")
      raise InvalidPlan, "锁 #{ref} 的 ref 节点缺 object.sha：#{rows.first.inspect[0, 200]}" unless sha

      commit = gateway.get_lock_commit(sha)
      parse_credential(commit.is_a?(Hash) ? commit["message"].to_s : "", ref)
    end

    def parse_credential(message, ref)
      return :unreadable if message.empty?

      credential = JSON.parse(message)
      missing = CREDENTIAL_FIELDS.reject { |field| credential.key?(field) }
      unknown = credential.keys.reject { |key| CREDENTIAL_FIELDS.include?(key) }
      valid = missing.empty? && unknown.empty? &&
              credential["purpose"].is_a?(String) && !credential["purpose"].empty? &&
              (credential["issue"].nil? || credential["issue"].is_a?(Integer)) &&
              credential["coordinator_id"].is_a?(String) && credential["host"].is_a?(String) &&
              credential["pid"].is_a?(Integer) && credential["lock_id"].is_a?(String)
      return :unreadable unless valid

      credential
    rescue JSON::ParserError
      :unreadable
    end

    # 建 commit（message=凭据 JSON）→ 建 ref。ref 已存在（422 already exists）
    # 返回 :duplicate——本次未拿到锁；commit 对象无 ref 指向会被 GitHub 回收，
    # 无需清理。其余错误上抛。
    def create_lock(gateway, ref, credential)
      raw = gateway.create_lock_commit(JSON.generate(credential), allow_write: true)
      commit = raw.is_a?(String) ? JSON.parse(raw) : raw
      sha = commit.is_a?(Hash) ? commit["sha"] : nil
      raise InvalidPlan, "锁 #{ref} 的 commit 创建结果缺 sha：#{commit.inspect[0, 200]}" unless sha

      begin
        gateway.create_lock_ref(ref, sha, allow_write: true)
        :ok
      rescue CommandError => e
        raise unless e.message.match?(/already\s+exists/i)

        :duplicate
      end
    end
  end
end
