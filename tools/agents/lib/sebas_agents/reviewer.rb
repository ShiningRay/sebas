# frozen_string_literal: true

module SebasAgents
  # Reviewer：只复核 Verifier 的应修项、可留项与未实测项，不重跑全量核验。
  # checker 由调用方注入；未注入时不得把「自报已修」当成通过。
  #
  # fixes 结构（键两种都接受，条目 id 优先）：
  #   { "must_fix-1" => {"commit" => "...", "passed" => true, "reason" => "..."},
  #     "g"         => {"commit" => "...", "passed" => true} }   # 条目自身 id
  #     "acceptable-2" => {"reason_still_valid" => true, "note" => "..."}
  module Reviewer
    module_function

    # fixes 键解析：先按条目自身 id 找，再按「同 level 内的序号」生成 fallback 键
    # （must_fix-1 …）。两条路都找不到才算未修复——不能因为键写法不同就误判。
    #
    # 三级兜底严格受限：
    #   - 条目 id 精确匹配，永远优先；
    #   - 位置键按 level 内 1-based 序号构造，不由 id 后缀推断（避免 r2-1/r3-1 撞键）；
    #     但位置键本身可能就是**另一条目**的显式 id（如首项 id=must_fix-2），
    #     这种情况下不得复用，否则一条 fix 会同时满足两项；
    #   - 纯 level 简写只在同 level 恰有一项时生效，否则一项修复会放行多项。
    def lookup(fixes, item, position, level_counts, reserved_ids)
      direct = fixes[item.id]
      return direct if direct.is_a?(Hash)

      positional_key = "#{item.level}-#{position}"
      positional = fixes[positional_key]
      if positional.is_a?(Hash) && !reserved_ids.include?(positional_key)
        return positional
      end

      level_key = fixes[item.level]
      level_key.is_a?(Hash) && level_counts[item.level] == 1 ? level_key : nil
    end

    def final_verification(verifier_report, fixes, checker: nil)
      report = VerificationReport.new
      # 不能用共享状态：module_function 下的实例变量会跨调用残留。
      # 注意 tally 带块时按「块的返回值」逐个计数，这里要的是每个 level 的条目数。
      level_counts = verifier_report.items.group_by(&:level).transform_values(&:length)
      reserved_ids = verifier_report.items.map(&:id)

      if verifier_report.blockers.any?
        report.blocker("Verifier 存在未解决阻断项：#{verifier_report.blockers.map(&:message).join("；")}")
      end

      verifier_report.must_fix_items.each_with_index do |item, index|
        fix = lookup(fixes, item, index + 1, level_counts, reserved_ids)
        unless fix.is_a?(Hash)
          report.blocker("应修项 #{item.id} 未修复：#{item.message}")
          next
        end

        if checker
          result = checker.call(item, fix)
          if result.is_a?(Hash) && result[:passed] == true
            report.ok("应修项 #{item.id} 已收口")
          else
            reason = result.is_a?(Hash) ? result[:reason] : "checker 返回非法结果"
            report.blocker("应修项 #{item.id} 修复不完整：#{reason}")
          end
          next
        end

        # 无独立复跑：passed 必须显式为 true，且必须给出 commit 佐证。
        if fix["passed"] == true && fix["commit"].to_s != ""
          report.unverified("应修项 #{item.id} 按提交 #{fix["commit"]} 自报已修复，Reviewer 未独立复跑")
        else
          report.blocker("应修项 #{item.id} 无独立验证结果#{fix["reason"] ? "：#{fix["reason"]}" : ""}")
        end
      end

      verifier_report.acceptable_items.each_with_index do |item, index|
        fix = lookup(fixes, item, index + 1, level_counts, reserved_ids)
        if fix.is_a?(Hash) && fix["reason_still_valid"] == true
          report.acceptable("可留项 #{item.id} 理由仍成立：#{item.message}")
        elsif fix.is_a?(Hash) && fix["reason_still_valid"] == false
          report.must_fix("可留项 #{item.id} 的理由已失效：#{fix["note"] || item.message}")
        else
          report.must_fix("可留项 #{item.id} 未复核其理由是否仍成立：#{item.message}")
        end
      end

      verifier_report.unverified_items.each do |item|
        if item.evidence.to_s.empty?
          report.blocker("未实测项 #{item.id} 无间接证据")
        else
          report.unverified("#{item.message}（间接证据：#{item.evidence}）")
        end
      end

      report
    end
  end
end
