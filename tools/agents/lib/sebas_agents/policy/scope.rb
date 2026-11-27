# frozen_string_literal: true

module SebasAgents
  module Policy
    # scope 冲突预算（M4x-Parallel-WP2，#220 落地纯函数，M4x-Parallel-WP3，#221 接线）。
    #
    # scope 是调度预算，不是沙箱：越界靠事后检测（worker 推送前自查 +
    # coordinator 合并队列前用 pr.files 复查），安全边界不依赖模型守约。
    # 冲突判定从保守：两个 scope 里任一路径前缀互相包含即冲突——
    # `src/` 与 `src/bus/x.cr` 冲突，`src/bus/` 与 `src/keys/` 不冲突；
    # 不猜测「同目录不同文件能否共存」。
    #
    # 缺 scope 的独占语义（Proposal §6.2 Q4=A 强制）：
    # - 在途任一租约缺 scope → 不认领任何新卡（无从判定是否重叠）；
    # - 候选缺 scope → 只在没有任何在途租约时可认领。
    # 两条合起来是「缺 scope 的卡独占全部容量」。
    module Scope
      module_function

      # 校验并归一 Automation.scope 数组（可选字段；nil = 未声明）。
      # 规则（§6.1）：非空字符串数组；不含 `..`；不以 `/` 开头；尾部 `/` 归一。
      # 非法值上抛 InvalidPlan——scope 是调度预算，声明非法不能静默忽略。
      def normalize(values, issue_number: nil)
        return nil if values.nil?

        prefix = issue_number ? "##{issue_number} 的 " : ""
        raise InvalidPlan, "#{prefix}automation.scope 必须是字符串数组" unless values.is_a?(Array)
        raise InvalidPlan, "#{prefix}automation.scope 不能为空数组" if values.empty?

        values.map do |value|
          unless value.is_a?(String) && !value.empty?
            raise InvalidPlan, "#{prefix}automation.scope 条目必须是非空字符串"
          end
          raise InvalidPlan, "#{prefix}automation.scope 不允许 `..`（#{value.inspect}）" if value.include?("..")
          # 归一 ./ 前缀（./docs 与 docs 同义，须先归一再判冲突）
          value = value.sub(%r{\A\./}, "")
          raise InvalidPlan, "#{prefix}automation.scope 不允许以 / 开头（#{value.inspect}）" if value.start_with?("/")
          raise InvalidPlan, "#{prefix}automation.scope 条目不能只剩空（#{value.inspect}）" if value.empty?

          value.end_with?("/") ? value : "#{value}/"
        end
      end

      # 冲突判定：归一化后任一路径前缀互相包含即冲突。
      # 空数组/nil（未声明）不参与冲突判定——缺 scope 的独占语义由 blocking_lease 处理。
      def conflict?(scope_a, scope_b)
        return false if scope_a.nil? || scope_b.nil?

        scope_a.any? { |a| scope_b.any? { |b| a.start_with?(b) || b.start_with?(a) } }
      end

      # 候选与在途租约之间的阻断判定（§6.2 Q4=A）。
      # 返回 [原因文本, 对方 issue 号] 或 nil（可并行）。三条规则按序：
      #   1. 候选缺 scope：只有在没有任何在途租约时才放行；
      #   2. 任一在途租约缺 scope：不认领新卡（无从判定重叠）；
      #   3. 前缀包含即冲突。
      # 原因文本直接进 excluded.detail，保持与 next 的措辞一致口径。
      def blocking_lease(candidate_scope, active_leases)
        return nil if active_leases.empty?

        if candidate_scope.nil?
          other = active_leases.first
          return ["候选缺 scope，只能在无其他在途租约时认领（在途 ##{other[:issue]}）", other[:issue]]
        end

        missing = active_leases.find { |lease| lease[:scope].nil? }
        if missing
          return ["在途 ##{missing[:issue]} 未声明 scope，无法判定冲突，暂停新认领", missing[:issue]]
        end

        hit = active_leases.find { |lease| conflict?(candidate_scope, lease[:scope]) }
        return nil unless hit

        ["scope 与在途 ##{hit[:issue]} 重叠（#{overlap_detail(candidate_scope, hit[:scope])}）", hit[:issue]]
      end

      # 命中的前缀对，用于 reason 里说清重叠在哪。
      def overlap_detail(scope_a, scope_b)
        pairs = scope_a.product(scope_b).select do |a, b|
          a.start_with?(b) || b.start_with?(a)
        end
        pairs.map { |a, b| a == b ? a : "#{a} ↔ #{b}" }.uniq.join("；")
      end

      # 把在途 issue 转成 budget 输入。scope 归一失败按未声明处理：
      # 在途卡的声明非法不该静默变成「不冲突」，而 blocking_lease 的
      # 「在途缺 scope」分支会让它独占容量——保守方向正确。
      def lease_of(issue)
        raw = issue.automation.is_a?(Hash) ? issue.automation["scope"] : nil
        scope = begin
          normalize(raw, issue_number: issue.number)
        rescue InvalidPlan
          nil
        end
        {issue: issue.number, scope: scope}
      end

      def leases_of(issues)
        Array(issues).map { |issue| lease_of(issue) }
      end

      # 候选过滤（plan 与 evaluate_milestone 共用）：与在途租约冲突的候选
      # 进 excluded。返回 [ready, excluded_rows]；excluded 行含 reason/other。
      # 候选之间不比：它们不是同时在途，每次 claim 只取一张，下一轮会重算。
      def filter_candidates(candidates, active_leases)
        return [candidates, []] if active_leases.empty?

        ready = []
        excluded = []
        candidates.each do |issue|
          scope = issue.automation.is_a?(Hash) ? issue.automation["scope"] : nil
          reason, other = blocking_lease(scope, active_leases)
          if reason
            excluded << {issue: issue.number, reason: reason, other: other, scope: scope}
          else
            ready << issue
          end
        end
        [ready, excluded]
      end
    end
  end
end
