# 最小 cron 表达式解析（M2-WP3，A10：cron owner 加账号维度）：
# 5 字段（分 时 日 月 周），支持 * / 数字 / */n / a-b / a,b 列表。
# next_after 计算下一个触发时刻（本地无时区语义，按 UTC）。
module Sebas
  module Orchestration
    module Cron
      class CronError < ::Exception; end

      record Fields, minute : Set(Int32), hour : Set(Int32), day : Set(Int32), month : Set(Int32), weekday : Set(Int32)

      def self.parse(expr : String) : Fields
        parts = expr.split(" ", remove_empty: true)
        raise CronError.new("cron must have 5 fields (got #{parts.size})") unless parts.size == 5
        Fields.new(
          field(parts[0], 0, 59), field(parts[1], 0, 23), field(parts[2], 1, 31),
          field(parts[3], 1, 12), field(parts[4], 0, 6)
        )
      end

      private def self.field(part : String, min : Int32, max : Int32) : Set(Int32)
        values = Set(Int32).new
        part.split(",").each do |item|
          step = 1
          range_str = item
          if slash = item.index("/")
            range_str = item[0...slash]
            step = item[(slash + 1)..].to_i?
            raise CronError.new("bad step in '#{item}'") unless step && step.positive?
          end
          lo, hi = range_bounds(range_str, min, max)
          hi = max if range_str == "*" && step > 1 && hi == lo
          (lo..hi).each { |v| values << v if (v - lo) % step == 0 }
        end
        raise CronError.new("empty field '#{part}'") if values.empty?
        values
      end

      private def self.range_bounds(range_str : String, min : Int32, max : Int32) : Tuple(Int32, Int32)
        if range_str == "*"
          return {min, max}
        end
        if dash = range_str.index("-")
          lo = range_str[0...dash].to_i?
          hi = range_str[(dash + 1)..].to_i?
          raise CronError.new("bad range '#{range_str}'") unless lo && hi
          return {lo, hi}
        end
        v = range_str.to_i?
        raise CronError.new("bad value '#{range_str}'") unless v
        {v, v}
      end

      # 下一个触发时刻（严格晚于 after；逐分钟步进，最多扫 366 天）
      def self.next_after(expr : String, after : Time = Time.utc) : Time
        fields = parse(expr)
        t = (after + 1.minute).at_beginning_of_minute
        limit = t + 366.days
        while t < limit
          return t if fields.minute.includes?(t.minute) && fields.hour.includes?(t.hour) &&
                      fields.month.includes?(t.month) && day_matches?(fields, t)
          t += 1.minute
        end
        raise CronError.new("no fire time within a year for '#{expr}'")
      end

      # DOM/DOW 标准语义：两者都非 * 时 OR，否则 AND
      private def self.day_matches?(fields : Fields, t : Time) : Bool
        dom = fields.day.includes?(t.day)
        dow = fields.weekday.includes?(t.day_of_week.value % 7)
        restricted_dom = fields.day.size != full_size(fields.day)
        restricted_dow = fields.weekday.size != full_size(fields.weekday)
        if restricted_dom && restricted_dow
          dom || dow
        else
          dom && dow
        end
      end

      private def self.full_size(set : Set(Int32)) : Int32
        set.size # 调用方传入即界内全集或子集；* 时 size=界宽
      end
    end
  end
end
