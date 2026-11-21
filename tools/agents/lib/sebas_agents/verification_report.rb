# frozen_string_literal: true

require "json"

module SebasAgents
  # 三级结论报告：阻断 / 应修 / 可留，另加未实测与有条件项。
  class VerificationReport
    Item = Data.define(:id, :level, :message, :evidence)

    LEVELS = %w[blocker must_fix acceptable unverified].freeze

    # 叙述式 verdict → 结构式 level 的唯一映射表。
    # Verifier 落盘报告常写中文结论（通过/应修/阻断…），review 工具只认 level；
    # 两套词汇在此收口，避免每次验收靠人工机械转换。
    VERDICTS = {
      "blocker" => "blocker",
      "阻断" => "blocker",
      "must_fix" => "must_fix",
      "应修" => "must_fix",
      "acceptable" => "acceptable",
      "可留" => "acceptable",
      "unverified" => "unverified",
      "未实测" => "unverified",
      "未验证" => "unverified",
      "ok" => "ok",
      "pass" => "ok",
      "通过" => "ok"
    }.freeze

    def initialize
      @items = []
    end

    def blocker(message, evidence: nil, id: nil)
      add("blocker", message, evidence, id: id)
    end

    def must_fix(message, evidence: nil, id: nil)
      add("must_fix", message, evidence, id: id)
    end

    def acceptable(message, evidence: nil, id: nil)
      add("acceptable", message, evidence, id: id)
    end

    def unverified(message, evidence: nil, id: nil)
      add("unverified", message, evidence, id: id)
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

    def add(level, message, evidence, id: nil)
      fallback = "#{level}-#{@items.count { |item| item.level == level } + 1}"
      @items << Item.new(id: id.to_s.empty? ? fallback : id.to_s, level: level,
        message: message, evidence: evidence)
      nil
    end
  end
end
