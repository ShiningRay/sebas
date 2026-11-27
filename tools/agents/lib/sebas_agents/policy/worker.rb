# frozen_string_literal: true

require "socket"
require "time"

module SebasAgents
  module Policy
    # worker 存活判定（#221 §5 F5）。从 Routing 拆出：它只回答「这张在途卡的
    # worker 还在不在」，与路由的其他分支没有共享状态，独立后路由保持可读。
    #
    # 为什么需要两个证据：心跳与 pid 各有失效方式。
    # - 只看 pid：pid 会被复用（旧 pid 恰被别的进程占用），死 worker 看起来活着。
    # - 只看心跳：长任务期间 worker 可能几十分钟不写心跳，活 worker 被判死。
    # 两个都成立才判「已死」；任一成立即「活着」；其余一律「未知」，按现状续做。
    module Worker
      extend self

      # 默认心跳 TTL。Implementer 一轮工具调用通常远短于此，而「卡死 15 分钟」
      # 已经久到值得让 coordinator 看一次。
      TTL = 900

      # 返回 [state, detail]：
      #   :alive   —— 能证明 worker 还在（心跳新鲜，或本机 pid 存活）→ 不接管
      #   :gone    —— 能证明 worker 已死（心跳过期 且 本机 pid 明确不存在）→ 可接管
      #   :foreign —— 记录写着别的主机 → 不是本机租约，不接管（F6）
      #   :unknown —— 证据不足 → 按现状续做，不额外阻塞
      #
      # 顺序有讲究：
      # 1. 跨机先分流：pid 在别的主机上没有意义，抢别人的卡比晚一轮贵得多。
      #    缺 host 不等于「别的主机」——旧记录没有该字段，只能算未知；判 foreign
      #    会让升级前的老记录全部停摆。
      # 2. 心跳新鲜 → 活着。「心跳新鲜但 pid 已消失」说明刚崩，冲突时以不接管为准。
      # 3. pid 存活 → 活着（长跑期间没写心跳也是活的）。
      # 4. 没有心跳字段的老记录 → unknown：升级当次不能把每张在途卡都判死，
      #    所以缺字段不构成「过期」证据，pid 单独不足以判死。
      # 5. 心跳过期 + 本机 + pid 明确不存在 → gone。
      def state(record, now: Time.now.utc, ttl: TTL)
        return [:unknown, "缺本地记录"] unless record

        # 缺 host 不能当本机：本机 pid 不存在证明不了「异机的原 worker 已停」，
        # 判 :gone 会派第二个 worker 去写同一分支。只有明确是同机才允许 pid 判据。
        host = record["host"].to_s
        return [:unknown, "记录缺 host，无法确认是否本机租约"] if host.empty?
        return [:foreign, "租约属主机 #{host.inspect}"] if host != Socket.gethostname

        pid = pid_of(record)
        has_stamp = record.key?("last_heartbeat_at")
        stamp = record["last_heartbeat_at"]

        return [:alive, "心跳 #{stamp} 未过期"] if fresh?(stamp, now, ttl)
        return [:alive, "pid #{pid} 存活"] if alive?(pid)
        return [:unknown, "旧记录无心跳字段"] unless has_stamp
        return [:unknown, "心跳已过期但记录缺 pid"] if pid.nil?

        [:gone, "心跳已过期且 pid #{pid} 不存在"]
      end

      # 心跳是否新鲜。空/非法时间戳按「不新鲜」——那属于记录被写坏，不能当存活证据。
      def fresh?(stamp, now = Time.now.utc, ttl = TTL)
        return false if stamp.nil? || stamp.to_s.empty?

        Time.iso8601(stamp.to_s) >= now - ttl
      rescue ArgumentError
        false
      end

      # pid 归一：save 写整数，外部手改可能是字符串。非正整数一律 nil。
      # 字符串必须与整数同口径检查 positive?：`"0"` 转成 0 后
      # `Process.kill(0, 0)` 探测的是**当前进程组**，会让过期记录被判成存活。
      def pid_of(record)
        pid = record && record["pid"]
        value = case pid
                when Integer then pid
                when String then pid.match?(/\A\d+\z/) ? pid.to_i : nil
                end
        value&.positive? ? value : nil
      end

      # `kill(0, pid)`：ESRCH = 不存在；EPERM = 存在但无权发信号（活着）。
      def alive?(pid)
        return false if pid.nil?

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end
    end
  end
end
