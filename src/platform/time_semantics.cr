# 纯函数时间语义（M5.0-WP2 #64）：提案 §4.2 四类时间表示、比较排序、
# DST 缺口与歧义本地时刻解析。契约细则见
# docs/design/proposals/time-semantics-storage.md（§时间）。
#
# 约束：无 IO、不读时钟、无全局可变状态——同输入恒同输出，spec 可在
# 三平台以固定 tzdata 规则（2007 年后美国 DST 规则稳定）复现期望值。
#
# DST 边界口径（B.9 验收三条，不接受平移猜测）：
#   ① 春季缺口：本地时刻不存在 → 拒绝并返回 needs_user_choice（绝不平移）；
#   ② 秋季重复：本地时刻出现两次 → 取 UTC 时刻较早者（即偏移较大者，
#      如 EDT −04:00 早于 EST −05:00），并以 Resolution#ambiguous? 标注；
#   ③ 全天 DATE：年月日数据类型自身无时区绑定，跨时区读取不漂移。
module Sebas
  module Platform
    module TimeSemantics
      # 缺口错误码常量：契约口径「需用户选择」——调用方据此把决定权交还用户。
      NEEDS_USER_CHOICE = "needs_user_choice"

      # 春季缺口错误：本地时刻在目标时区不存在。禁止自动平移（stdlib
      # `Time.local` 对缺口会静默平移到偏移前时刻，本模块不采用该行为）。
      class GapError < ::Exception
        # 稳定错误码：领域层按码分支，不解析消息文本。
        getter code : String

        def initialize(message : String)
          @code = NEEDS_USER_CHOICE
          super(message)
        end
      end

      # 四类时间表示（提案 §4.2）。文档枚举名与存储列的对应关系：
      # Instant→due_at 类列；WallClock→due_wall+due_tz；AllDay→DATE 列；
      # Floating→无时区信息的墙钟值（首版仅比较，不入排序队列）。
      enum Kind
        Instant
        WallClock
        AllDay
        Floating
      end

      # 全天日期：年月日三元组，无时区绑定（口径③：跨时区读取不漂移——
      # DATE 的相等与排序只看字段本身，与时区无关）。
      record LocalDate, year : Int32, month : Int32, day : Int32 do
        include Comparable(LocalDate)

        def <=>(other : LocalDate) : Int32
          {year, month, day} <=> {other.year, other.month, other.day}
        end

        def to_s(io : IO) : Nil
          io << "%04d-%02d-%02d" % {year, month, day}
        end
      end

      # 墙钟字段：日期 + 当地时刻，尚未绑定任何 UTC 偏移。
      # WallClock 与 Floating 共用本类型；区别仅在是否携带 IANA 时区名，
      # 时区名由调用方列存储（due_tz），不进本结构。
      record LocalWall, year : Int32, month : Int32, day : Int32,
        hour : Int32 = 0, minute : Int32 = 0, second : Int32 = 0, nanosecond : Int32 = 0 do
        include Comparable(LocalWall)

        # Floating 的排序规则：墙钟字段字典序（不绑定时区，不换算 UTC）。
        def <=>(other : LocalWall) : Int32
          {year, month, day, hour, minute, second, nanosecond} <=>
            {other.year, other.month, other.day, other.hour, other.minute,
             other.second, other.nanosecond}
        end
      end

      # 解析状态闭集：Unique / Ambiguous / Gap。
      enum ResolveStatus
        Unique
        Ambiguous
        Gap
      end

      # 墙钟时刻解析结果。primary 约定：Unique→唯一解；Ambiguous→两候选中
      # **UTC 时刻较早者**（判定式：比较两候选的 UTC 时刻，取较早者——
      # 对同一墙钟值即 UTC 偏移较大者，如 EDT −04:00）；Gap→nil。
      struct Resolution
        getter status : ResolveStatus
        getter primary : Time?
        getter secondary : Time?

        def initialize(@status : ResolveStatus, @primary : Time?, @secondary : Time?)
        end

        # 秋季重复标记：契约字段名 ambiguous_local_time（对象上标注用）。
        def ambiguous? : Bool
          @status.ambiguous?
        end

        def gap? : Bool
          @status.gap?
        end
      end

      # 解析探测窗口：偏移探测点取墙钟伪 UTC 值 ±48h。IANA 现行时区
      # 相邻两次变迁间隔远大于 96h，±48h 足以覆盖窗口两侧的稳定偏移。
      private PROBE_WINDOW = 48 * 3600

      # 把墙钟字段解析为 UTC 时刻（核心入口）。
      #
      # 算法：以墙钟字段的伪 UTC 值为基准，取 ±窗口两点的现行偏移各构造
      # 一个候选 UTC 时刻，再用「回读墙钟字段是否与输入一致」过滤——
      # 0 个有效 → Gap（本地时刻不存在）；1 个 → Unique；2 个 → Ambiguous。
      def self.resolve_wall(w : LocalWall, tz : Time::Location) : Resolution
        validate!(w)
        naive = Time.utc(w.year, w.month, w.day, w.hour, w.minute, w.second,
          nanosecond: w.nanosecond)
        base = naive.to_unix
        pre = tz.lookup(base - PROBE_WINDOW).offset
        post = tz.lookup(base + PROBE_WINDOW).offset
        candidates = [Time.unix(base - pre).shift(0, w.nanosecond),
                      Time.unix(base - post).shift(0, w.nanosecond)].uniq(&.to_unix)

        valid = candidates.select { |candidate| wall_matches?(candidate, w, tz) }
        case valid.size
        when 0
          Resolution.new(ResolveStatus::Gap, nil, nil)
        when 1
          Resolution.new(ResolveStatus::Unique, valid[0], nil)
        else
          ordered = valid.sort_by(&.to_unix)
          Resolution.new(ResolveStatus::Ambiguous, ordered[0], ordered[1])
        end
      end

      # resolve_wall 的严格形态：缺口即抛 `GapError`（错误码 needs_user_choice），
      # 供「不能缺省必须拒绝」的调用方（如截止时刻入库）使用。
      def self.resolve_wall!(w : LocalWall, tz : Time::Location) : Time
        res = resolve_wall(w, tz)
        primary = res.primary
        raise GapError.new("本地时刻 #{w} 在时区 #{tz.name} 不存在（DST 缺口），需用户选择") if primary.nil?
        primary
      end

      # 全天 DATE 的当日开始锚：归属时区当日语义下的 00:00（严格解析——
      # 午夜恰逢缺口的时区同样拒绝并要求用户选择，不平移）。
      def self.day_anchor(d : LocalDate, tz : Time::Location) : Time
        resolve_wall!(LocalWall.new(d.year, d.month, d.day), tz)
      end

      # interval 语义比较：UTC 时刻对全天日的位置。
      # 返回 −1（时刻在当日开始锚之前）/ 0（时刻落在当日 [锚, 次日锚) 区间内）/
      # +1（时刻在次日锚及之后）。这是区间比较而非全序比较——统一排序队列
      # 请改用 day_anchor 参与排序（§时间 排序规则）。
      def self.instant_vs_all_day(instant : Time, d : LocalDate, tz : Time::Location) : Int32
        start = day_anchor(d, tz)
        next_day_anchor = day_anchor(next_day(d), tz)
        return -1 if instant < start
        return 1 if instant >= next_day_anchor
        0
      end

      # 次日（简单日历推进，月末日进位；不处理时区——由调用方拿结果再锚定）。
      def self.next_day(d : LocalDate) : LocalDate
        unless d.year.in?(1..9999) && d.month.in?(1..12)
          raise ArgumentError.new("日期字段非法：#{d}")
        end
        days_in_month = {0, 31, leap?(d.year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}[d.month]
        if d.day < days_in_month
          LocalDate.new(d.year, d.month, d.day + 1)
        elsif d.month < 12
          LocalDate.new(d.year, d.month + 1, 1)
        else
          LocalDate.new(d.year + 1, 1, 1)
        end
      end

      private def self.leap?(year : Int32) : Bool
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
      end

      private def self.validate!(w : LocalWall) : Nil
        # 先判字段范围再查月长表：越界月份不得触发元组越界（契约是 ArgumentError）
        unless w.year.in?(1..9999) && w.month.in?(1..12) && w.hour.in?(0..23) &&
               w.minute.in?(0..59) && w.second.in?(0..59) &&
               w.nanosecond.in?(0..999_999_999)
          raise ArgumentError.new("墙钟字段非法：#{w}")
        end
        days = {0, 31, leap?(w.year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}[w.month]
        unless w.day.in?(1..days)
          raise ArgumentError.new("墙钟字段非法：#{w}")
        end
      end

      private def self.wall_matches?(candidate : Time, w : LocalWall, tz : Time::Location) : Bool
        t = candidate.in(tz)
        t.year == w.year && t.month == w.month && t.day == w.day &&
          t.hour == w.hour && t.minute == w.minute && t.second == w.second &&
          t.nanosecond == w.nanosecond
      end
    end
  end
end
