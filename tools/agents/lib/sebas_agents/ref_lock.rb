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
  # 删除不能只按名字删：GitHub 的 DELETE 无条件原语，两个并发接管者都能
  # 「删旧建新」而互不报错，会双双进入临界区。因此每把主锁配一把**声明锁**
  # （claim），把「删除主锁」的权限收敛到声明锁持有者手里：
  # - 主锁的创建恒为 CAS（互斥根）；持有者无需声明锁。
  # - 任何要删主锁的动作（接管、释放）必须先 CAS 拿到声明锁；持声明锁期间
  #   删除前再比对 lock_id 与观察值，不匹配即放弃——声明锁保证无并发删除者，
  #   比对关掉「释放删掉接管者新锁」的窗口。
  # - 声明锁自身的残留（接管者在删主锁前崩溃）按同一 judge 判残锁接管；
  #   声明窗口只有三次 API 调用，残留概率极低。
  #
  # 时长分层（implementer-loop §5 / 续篇 §4 口径）：
  # - 锁是**命令级**的：只包住 claim/unclaim/mark-review/queue 的写段
  #   （几次 gh API 调用，秒级）。任务开工后锁即释放，干活期间不持锁。
  # - 任务级所有权仍由租约评论（Lease）承担：state=active 覆盖整个任务期，
  #   别的机器认领同卡会先拿到锁、再被租约预检拒绝。F9 语义不动。
  # - TTL 只决定「持锁进程写命令中途崩溃留下的残锁，多久后允许异机接管」：
  #   缺省 60 分钟（lock_ttl_minutes），宁大勿小——调大不削弱互斥，
  #   只拉长残锁等待；残锁按逐卡 ref 命名，只阻塞对应那张卡的写命令。
  #   已知残余风险（recovery §4 披露）：持锁进程存活但写段超过 TTL 时，
  #   接管可与其并发——锁不向下游写入提供 fencing token。
  module RefLock
    LOCK_PREFIX = "refs/locks/sebas"
    # 声明锁独立前缀树：避免与主锁共享 matching-refs 前缀查询空间。
    CLAIM_PREFIX = "refs/locks/sebas-claims"
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

    # 声明锁名：主锁尾部段映射到独立前缀树（lease-11 → lease-11）。
    def claim_ref_for(ref)
      "#{CLAIM_PREFIX}/#{ref.split("/").last}"
    end

    # 尝试拿锁。网络/权限类 CommandError 不在此翻译，直接上抛——
    # 调用方按「写入失败」路径处理，不得把「读不到」当成「没有锁」。
    def acquire!(gateway, ref:, purpose:, issue: nil, ttl_seconds: DEFAULT_TTL_MINUTES * 60,
                 grace_seconds: GRACE_SECONDS, attempts: 3)
      attempts.times do
        holder = read_holder(gateway, ref)
        if holder.nil?
          credential = new_credential(purpose: purpose, issue: issue)
          return acquired_outcome(credential) if create_lock(gateway, ref, credential) == :ok

          next # 422：并发方先建——重读重判
        end
        return held_unreadable(ref) if holder == :unreadable

        verdict = judge(holder, ref: ref, ttl_seconds: ttl_seconds, grace_seconds: grace_seconds)
        return verdict if verdict.held?

        # 可接管：先拿声明锁，持声明权期间完成「删旧建新」。
        outcome = claim_and_replace!(gateway, ref: ref, previous: holder, purpose: purpose,
          issue: issue, ttl_seconds: ttl_seconds, grace_seconds: grace_seconds)
        return outcome unless outcome == :retry
      end

      held_outcome(ref, nil, ["锁 #{ref} 的接管竞争连续 #{attempts} 轮未决（并发接管/释放频繁），不重试", "需人工核对"])
    end

    # 释放锁：先回读凭据，确认还是自己的才删。已被接管（lock_id 不匹配）
    # 或凭据不可解析 → 不删，通过 payload 上报，fail-closed。
    # ttl_seconds 供「声明锁残留接管」判定，与 acquire! 同源传入。
    # dry-run 演练没有写动作（与 acquire 侧口径一致），直接按已释放放行。
    def release!(gateway, ref:, lock_id:, payload: nil, ttl_seconds: DEFAULT_TTL_MINUTES * 60)
      return true if gateway.respond_to?(:dry_run?) && gateway.dry_run?

      holder = read_holder(gateway, ref)
      return true if holder.nil? # 锁已消失：等效已释放

      if holder == :unreadable || holder["lock_id"] != lock_id
        if payload
          payload["lock_release_mismatch"] =
            "锁 #{ref} 已不是本次获取者持有（#{holder_summary(holder)}），不删除他人锁，需人工核对"
        end
        return false
      end

      # 删除前先拿声明权：接管者同样靠声明锁排他删除，双方不会互删。
      claim_ref = claim_ref_for(ref)
      claim, held = with_claim_exclusivity(gateway, claim_ref, issue: holder["issue"],
        ttl_seconds: ttl_seconds, grace_seconds: GRACE_SECONDS)
      if held
        if payload
          payload["lock_release_mismatch"] =
            "锁 #{ref} 的释放声明权被他人持有（#{holder_summary(held.holder)}），有接管或释放进行中，需人工核对"
        end
        return false
      end

      begin
        current = read_holder(gateway, ref)
        return true if current.nil? # 已被接管者处理：接管方会重建并记录接管

        if current == :unreadable || current["lock_id"] != lock_id
          if payload
            payload["lock_release_mismatch"] =
              "锁 #{ref} 在释放等待声明权期间已易主（#{holder_summary(current)}），不删除他人锁，需人工核对"
          end
          return false
        end

        gateway.delete_lock_ref!(ref, allow_write: true)
        true
      ensure
        release_claim!(gateway, claim_ref, claim)
      end
    end

    # ---- 声明锁协议 ----

    # 持声明权完成「删旧建新」接管。:retry 表示前提变化需外层重读重判。
    def claim_and_replace!(gateway, ref:, previous:, purpose:, issue:, ttl_seconds:, grace_seconds:)
      claim_ref = claim_ref_for(ref)
      claim, held = with_claim_exclusivity(gateway, claim_ref, issue: issue,
        ttl_seconds: ttl_seconds, grace_seconds: grace_seconds)
      return held if held

      begin
        current = read_holder(gateway, ref)
        if current.nil?
          # 主锁已消失（原持有者已释放）：直接 CAS 建新锁。
          credential = new_credential(purpose: purpose, issue: issue)
          if create_lock(gateway, ref, credential) == :ok
            return acquired_outcome(credential)
          end

          return :retry # 被并发建回：外层重读重判
        end
        if current == :unreadable || current["lock_id"] != previous["lock_id"]
          # 接管前提失效：主锁在等待声明权期间已易主/不可解析。
          return held_outcome(ref, current,
            ["锁 #{ref} 在等待接管声明权期间已易主（#{holder_summary(current)}），接管前提失效，需重判"])
        end

        # 删除绑定观察实例：声明权保证无并发删除者；lock_id 比对保证不删新锁。
        gateway.delete_lock_ref!(ref, allow_write: true)
        credential = new_credential(purpose: purpose, issue: issue)
        if create_lock(gateway, ref, credential) == :ok
          return Outcome.new(status: :acquired, credential: credential, holder: nil,
            reasons: [], previous: previous)
        end

        :retry # 极小窗口内被非协议方建回：外层重读重判
      ensure
        release_claim!(gateway, claim_ref, claim)
      end
    end

    # 独占声明权：CAS 拿声明锁；已存在时按 judge 判残声明（接管者在删主锁前
    # 崩溃的残留），可接管则绑定删除后重建。返回 [claim 凭据, nil] 或
    # [nil, held Outcome]（含 holder 供上报）。
    def with_claim_exclusivity(gateway, claim_ref, issue:, ttl_seconds:, grace_seconds:)
      claim = new_credential(purpose: "claim", issue: issue)
      return [claim, nil] if create_lock(gateway, claim_ref, claim) == :ok

      holder = read_holder(gateway, claim_ref)
      return [nil, held_outcome(claim_ref, nil,
        ["声明锁 #{claim_ref} 凭据不可解析（fail-closed），需人工核对"])] if holder == :unreadable
      return [nil, held_outcome(claim_ref, nil, ["声明锁 #{claim_ref} 状态异常：读取为空"])] if holder.nil?

      verdict = judge(holder, ref: claim_ref, ttl_seconds: ttl_seconds, grace_seconds: grace_seconds)
      unless verdict.held?
        # 残声明接管：删除绑定观察实例（重读比对 lock_id）。
        current = read_holder(gateway, claim_ref)
        if current.nil? || (current != :unreadable && current["lock_id"] == holder["lock_id"])
          gateway.delete_lock_ref!(claim_ref, allow_write: true)
          return [claim, nil] if create_lock(gateway, claim_ref, claim) == :ok
        end
        return [nil, held_outcome(claim_ref, nil,
          ["声明锁 #{claim_ref} 的接管被并发获取，不重试"])]
      end

      [nil, Outcome.new(status: :held, credential: nil, holder: holder,
        reasons: verdict.reasons, previous: nil)]
    end

    # 释放声明锁：绑定 lock_id，误删他人声明最坏触发对方重试，不破互斥。
    def release_claim!(gateway, claim_ref, claim)
      current = read_holder(gateway, claim_ref)
      return if current.nil? || current == :unreadable
      return unless current["lock_id"] == claim["lock_id"]

      gateway.delete_lock_ref!(claim_ref, allow_write: true)
    rescue StandardError
      # 声明残留有 judge 接管兜底，释放失败不阻塞业务结果。
      nil
    end

    # ---- 判定 ----

    # 持有者判活：:held（含接管证据不足的情形）或 :takeover 占位（此处返回
    # 一个非 held 的 Outcome，由 acquire!/claim 接管路径继续）。
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
    # matching-refs 按**前缀**匹配（lease-306 会命中 lease-3060）：先按完整
    # ref 名过滤再判零/一/多，不同编号的锁互不误伤。
    def read_holder(gateway, ref)
      rows = gateway.get_matching_refs(ref)
      unless rows.is_a?(Array)
        raise InvalidPlan, "锁 #{ref} 的 matching-refs 返回非数组：#{rows.inspect[0, 200]}"
      end

      rows = rows.select { |row| row.is_a?(Hash) && row["ref"] == ref }
      return nil if rows.empty?

      if rows.length > 1
        raise InvalidPlan, "锁 #{ref} 精确匹配到 #{rows.length} 条 ref（不可能状态）：需人工核对"
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

    def acquired_outcome(credential)
      Outcome.new(status: :acquired, credential: credential, holder: nil, reasons: [], previous: nil)
    end

    def held_unreadable(ref)
      Outcome.new(status: :held, credential: nil, holder: nil,
        reasons: ["锁 #{ref} 的凭据不可解析（fail-closed），需人工核对"], previous: nil)
    end

    def held_outcome(ref, holder, reasons)
      Outcome.new(status: :held, credential: nil, holder: holder, reasons: reasons, previous: nil)
    end
  end
end
