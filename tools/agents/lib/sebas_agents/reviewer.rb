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

    # fixes 键解析：先按条目自身 id 找，再退回 level 自编号（must_fix-1 …）。
    # 两条路都找不到才算「未修复」——不能因为键写法不同就误判。
    def lookup(fixes, item)
      direct = fixes[item.id]
      return direct if direct.is_a?(Hash)

      fallback = fixes[auto_key(item)]
      return fallback if fallback.is_a?(Hash)

      # 兼容只给 level 的简写：{"must_fix" => {...}} 仅在唯一同 level 项时生效。
      level_key = fixes[item.level]
      level_key.is_a?(Hash) ? level_key : nil
    end

    def auto_key(item)
      suffix = item.id.to_s.split("-").last
      "#{item.level}-#{suffix}"
    end

    def final_verification(verifier_report, fixes, checker: nil)
      report = VerificationReport.new

      if verifier_report.blockers.any?
        report.blocker("Verifier 存在未解决阻断项：#{verifier_report.blockers.map(&:message).join("；")}")
      end

      verifier_report.must_fix_items.each do |item|
        fix = lookup(fixes, item)
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

      verifier_report.acceptable_items.each do |item|
        fix = lookup(fixes, item)
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
