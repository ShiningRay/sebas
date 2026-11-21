# frozen_string_literal: true

require "json"

module SebasAgents
  # 三级结论报告：阻断 / 应修 / 可留，另加未实测与有条件项。
  class VerificationReport
    Item = Data.define(:id, :level, :message, :evidence)

    LEVELS = %w[blocker must_fix acceptable unverified].freeze

    def initialize
      @items = []
    end

    def blocker(message, evidence: nil)
      add("blocker", message, evidence)
    end

    def must_fix(message, evidence: nil)
      add("must_fix", message, evidence)
    end

    def acceptable(message, evidence: nil)
      add("acceptable", message, evidence)
    end

    def unverified(message, evidence: nil)
      add("unverified", message, evidence)
    end

    def ok(_message, evidence: nil)
      evidence
    end

    def blockers
      @items.select { |item| item.level == "blocker" }
    end

    def must_fix_items
      @items.select { |item| item.level == "must_fix" }
    end

    def acceptable_items
      @items.select { |item| item.level == "acceptable" }
    end

    def unverified_items
      @items.select { |item| item.level == "unverified" }
    end

    def items
      @items
    end

    def pass?
      blockers.empty? && must_fix_items.empty?
    end

    def conclusion
      return "打回" unless pass?
      return "有条件通过" if unverified_items.any?

      "通过"
    end

    def to_h
      {
        "conclusion" => conclusion,
        "counts" => LEVELS.to_h { |level| [level, @items.count { |item| item.level == level }] },
        "items" => @items.map { |item| {"id" => item.id, "level" => item.level, "message" => item.message, "evidence" => item.evidence} }
      }
    end

    def to_json(*args)
      JSON.pretty_generate(to_h, *args)
    end

    private

    def add(level, message, evidence)
      @items << Item.new(id: "#{level}-#{@items.length + 1}", level: level, message: message, evidence: evidence)
      nil
    end
  end
end
