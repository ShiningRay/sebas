# frozen_string_literal: true

module SebasAgents
  module Policy
    # scope 冲突预算（M4x-Parallel-WP2，#220；Proposal parallel-implementers.md §6）。
    #
    # scope 是调度预算，不是沙箱：越界靠事后检测（worker 推送前自查 +
    # coordinator 合并队列前用 pr.files 复查），安全边界不依赖模型守约。
    # 冲突判定从保守：两个 scope 里任一路径前缀互相包含即冲突——
    # `src/` 与 `src/bus/x.cr` 冲突，`src/bus/` 与 `src/keys/` 不冲突；
    # 不猜测「同目录不同文件能否共存」。
    #
    # 本期容量固定 1，scope 冲突过滤处于待命状态：纯函数先落地并测试，
    # 容量 >1 时由 plan 按「任一前缀互相包含即冲突」过滤候选（§6.1）。
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
      # 空数组/nil（未声明）不参与冲突判定——缺 scope 的独占语义由容量层处理。
      def conflict?(scope_a, scope_b)
        return false if scope_a.nil? || scope_b.nil?

        scope_a.any? { |a| scope_b.any? { |b| a.start_with?(b) || b.start_with?(a) } }
      end

      # 容量 >1 时的候选过滤：与任一在途租约 scope 冲突的候选进 excluded。
      # 返回 [ready_candidates, excluded_rows]；excluded 行 reason 写明对方卡
      # （§8.1 必测场景 4）。本期容量恒为 1，此方法暂不被 plan 调用，
      # 先以纯函数形态落地并测试（容量参数化是阶段 3 的事）。
      def filter_candidates(candidates, active_leases)
        return [candidates, []] if active_leases.empty?

        ready = []
        excluded = []
        candidates.each do |issue|
          scope = issue.automation["scope"]
          other = active_leases.find do |lease|
            conflict?(scope, lease[:scope]) || (scope.nil? || lease[:scope].nil?)
          end
          if other
            excluded << {issue: issue.number, other: other[:issue], scope: scope}
          else
            ready << issue
          end
        end
        [ready, excluded]
      end
    end
  end
end
