# frozen_string_literal: true

module SebasAgents
  module Policy
    # milestone description 的机器可读字段。只认 `order:` 与 `track:` 两行。
    module MilestoneMetadata
      MAIN_ORDER = /\A\d+\z/
      PARALLEL_ORDER = /\A\d+x\z/

      module_function

      def parse(description)
        fields = {}
        description.to_s.each_line do |line|
          key, value = line.split(":", 2)
          next unless value

          key = key.strip
          next unless %w[order track].include?(key)

          raise InvalidPlan, "milestone 字段 #{key} 重复" if fields.key?(key)

          fields[key] = value.strip
        end
        fields
      end

      # 返回 [order, track]；缺字段或格式非法一律 InvalidPlan。
      def order_and_track(description, subject:)
        fields = parse(description)
        order = fields["order"]
        track = fields["track"]
        raise InvalidPlan, "#{subject} 缺 order 或 track" if order.nil? || track.nil?

        case track
        when "main"
          raise InvalidPlan, "#{subject} 的 main order 必须是整数：#{order.inspect}" unless order.match?(MAIN_ORDER)
        when "parallel"
          unless order.match?(PARALLEL_ORDER)
            raise InvalidPlan, "#{subject} 的 parallel order 必须以 x 结尾：#{order.inspect}"
          end
        else
          raise InvalidPlan, "#{subject} 的 track 非法：#{track.inspect}"
        end
        raise InvalidPlan, "#{subject} 的 order 必须为正整数" unless Integer(order.delete_suffix("x"), 10).positive?

        [order, track]
      end
    end

    module Milestones
      module_function

      # 校验全部 milestone 的元数据；返回带解析字段的新列表。
      def normalize(milestones)
        normalized = milestones.map do |milestone|
          validate_state!(milestone)
          order, track = MilestoneMetadata.order_and_track(
            milestone.description,
            subject: "milestone ##{milestone.number} #{milestone.title}"
          )
          milestone.with(order: order, track: track)
        end

        main = normalized.select(&:main?)
        # 用数值比较，避免 "4" 与 "04" 绕过重复检测。
        duplicate = main.group_by(&:sort_key).select { |_order, items| items.length > 1 }
        if duplicate.any?
          keys = duplicate.map { |order, items| "#{order}（#{items.map(&:number).join("、")}）" }
          raise InvalidPlan, "主线 order 重复：#{keys.join("；")}"
        end
        normalized
      end

      def validate_state!(milestone)
        return if %w[open closed].include?(milestone.state)

        raise InvalidPlan, "milestone ##{milestone.number} 的 state 非法：#{milestone.state.inspect}"
      end

      # 唯一 active 主线：open 且仍有未完成工作的最小 order。
      # open_issues 是 GitHub 的缓存字段，可能滞后；调用方应同时参考实际 open 卡。
      # 返回 [action, milestone]：[:select, m] / [:handoff_release, nil] / [:idle, nil]
      def active(milestones, open_issue_counts: nil)
        main = milestones.select(&:main?).sort_by(&:sort_key)
        candidate = main.find do |item|
          next false unless item.open?

          if open_issue_counts
            open_issue_counts.fetch(item.number, 0).positive?
          else
            item.open_issues.positive?
          end
        end
        return [:select, candidate] if candidate
        return [:handoff_release, nil] if main.any?(&:open?)

        [:idle, nil]
      end
    end
  end
end
