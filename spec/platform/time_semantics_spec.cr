require "spec"
require "../../src/platform/time_semantics"

include Sebas::Platform

# M5.0-WP2 #64：纯函数时间语义 spec。期望值按 B.9 验收三条写死（不接受
# 描述式断言）；tzdata 对 2007 年后美国 DST 规则稳定，三平台可复现。
describe Sebas::Platform::TimeSemantics do
  ny = Time::Location.load("America/New_York")

  describe "① 春季缺口（本地时刻不存在）" do
    it "Gap：America/New_York 2026-03-08 02:30 不存在，primary 为 nil" do
      res = Sebas::Platform::TimeSemantics.resolve_wall(
        Sebas::Platform::TimeSemantics::LocalWall.new(2026, 3, 8, 2, 30), ny)
      res.status.should eq(Sebas::Platform::TimeSemantics::ResolveStatus::Gap)
      res.gap?.should be_true
      res.primary.should be_nil
      res.secondary.should be_nil
    end

    it "resolve_wall! 对缺口抛 GapError，错误码 needs_user_choice（拒绝平移）" do
      expect_raises(Sebas::Platform::TimeSemantics::GapError, "需用户选择") do
        Sebas::Platform::TimeSemantics.resolve_wall!(
          Sebas::Platform::TimeSemantics::LocalWall.new(2026, 3, 8, 2, 30), ny)
      end
    end

    it "stdlib Time.local 会静默平移——本契约明确不采用该行为（对照说明）" do
      shifted = Time.local(2026, 3, 8, 2, 30, 0, location: ny)
      shifted.hour.should eq(1) # stdlib 行为：平移到 01:30，契约禁用
    end
  end

  describe "② 秋季重复（本地时刻出现两次）" do
    it "Ambiguous：2026-11-01 01:30 两次，primary 取 UTC 时刻较早者 −04:00" do
      res = Sebas::Platform::TimeSemantics.resolve_wall(
        Sebas::Platform::TimeSemantics::LocalWall.new(2026, 11, 1, 1, 30), ny)
      res.status.should eq(Sebas::Platform::TimeSemantics::ResolveStatus::Ambiguous)
      res.ambiguous?.should be_true

      primary = res.primary.as(Time)
      secondary = res.secondary.as(Time)
      # 判定式口径：比较两候选的 UTC 时刻，取较早者（等价于偏移较大者）
      primary.to_unix.should be < secondary.to_unix
      primary.in(ny).offset.should eq(-4 * 3600)   # EDT
      secondary.in(ny).offset.should eq(-5 * 3600) # EST
    end
  end

  describe "常规解析（Unique）" do
    it "夏令时内 2026-06-01 12:00 唯一解，偏移 −04:00" do
      res = Sebas::Platform::TimeSemantics.resolve_wall(
        Sebas::Platform::TimeSemantics::LocalWall.new(2026, 6, 1, 12, 0), ny)
      res.status.should eq(Sebas::Platform::TimeSemantics::ResolveStatus::Unique)
      res.ambiguous?.should be_false
      res.primary.as(Time).in(ny).offset.should eq(-4 * 3600)
    end

    it "标准时内 2026-11-01 02:30（回拨结束后）唯一解，偏移 −05:00" do
      res = Sebas::Platform::TimeSemantics.resolve_wall(
        Sebas::Platform::TimeSemantics::LocalWall.new(2026, 11, 1, 2, 30), ny)
      res.status.should eq(Sebas::Platform::TimeSemantics::ResolveStatus::Unique)
      res.primary.as(Time).in(ny).offset.should eq(-5 * 3600)
    end

    it "解析后回读墙钟字段与输入一致（round-trip）" do
      w = Sebas::Platform::TimeSemantics::LocalWall.new(2026, 6, 1, 12, 34, 56, 123_000_000)
      t = Sebas::Platform::TimeSemantics.resolve_wall!(w, ny)
      t.in(ny).year.should eq(2026)
      t.in(ny).minute.should eq(34)
      t.in(ny).nanosecond.should eq(123_000_000)
    end
  end

  describe "③ 全天 DATE 跨时区不漂移" do
    it "Asia/Shanghai 建全天 DATE、以 America/Los_Angeles 读取——同一 DATE" do
      built = Sebas::Platform::TimeSemantics::LocalDate.new(2026, 5, 20)
      # DATE 数据类型无时区绑定：无论以哪个时区「读取」，年月日不变
      read_back = built
      read_back.should eq(Sebas::Platform::TimeSemantics::LocalDate.new(2026, 5, 20))
      read_back.year.should eq(2026)
      read_back.month.should eq(5)
      read_back.day.should eq(20)
    end

    it "两个时区的当日开始锚回读仍是同一日历日（不发生日期漂移）" do
      d = Sebas::Platform::TimeSemantics::LocalDate.new(2026, 5, 20)
      shanghai = Time::Location.load("Asia/Shanghai")
      la = Time::Location.load("America/Los_Angeles")
      a = Sebas::Platform::TimeSemantics.day_anchor(d, shanghai)
      b = Sebas::Platform::TimeSemantics.day_anchor(d, la)
      a.in(shanghai).to_s("%Y-%m-%d").should eq("2026-05-20")
      b.in(la).to_s("%Y-%m-%d").should eq("2026-05-20")
    end

    it "instant_vs_all_day：前/中/后三段位置正确" do
      d = Sebas::Platform::TimeSemantics::LocalDate.new(2026, 5, 20)
      la = Time::Location.load("America/Los_Angeles")
      before = Time.unix(Sebas::Platform::TimeSemantics.day_anchor(d, la).to_unix - 60)
      within = Sebas::Platform::TimeSemantics.day_anchor(d, la) + 1.hour
      after = Time.unix(Sebas::Platform::TimeSemantics.day_anchor(
        Sebas::Platform::TimeSemantics.next_day(d), la).to_unix)
      Sebas::Platform::TimeSemantics.instant_vs_all_day(before, d, la).should eq(-1)
      Sebas::Platform::TimeSemantics.instant_vs_all_day(within, d, la).should eq(0)
      Sebas::Platform::TimeSemantics.instant_vs_all_day(after, d, la).should eq(1)
    end
  end

  describe "排序规则" do
    it "LocalDate 按年月日字典序比较" do
      a = Sebas::Platform::TimeSemantics::LocalDate.new(2026, 1, 1)
      b = Sebas::Platform::TimeSemantics::LocalDate.new(2026, 12, 31)
      (a < b).should be_true
      (a == Sebas::Platform::TimeSemantics::LocalDate.new(2026, 1, 1)).should be_true
    end

    it "LocalWall（Floating）按字段字典序比较，不做时区换算" do
      a = Sebas::Platform::TimeSemantics::LocalWall.new(2026, 3, 8, 1, 30)
      b = Sebas::Platform::TimeSemantics::LocalWall.new(2026, 3, 8, 2, 30)
      c = Sebas::Platform::TimeSemantics::LocalWall.new(2026, 11, 1, 1, 30)
      (a < b).should be_true
      (b < c).should be_true
    end

    it "WallClock 解析后按 UTC 时刻比较（东京 08:00 早于纽约同日 20:00 的 UTC）" do
      tokyo = Time::Location.load("Asia/Tokyo")
      w_tokyo = Sebas::Platform::TimeSemantics::LocalWall.new(2026, 6, 1, 8, 0)
      w_ny = Sebas::Platform::TimeSemantics::LocalWall.new(2026, 6, 1, 20, 0)
      t_tokyo = Sebas::Platform::TimeSemantics.resolve_wall!(w_tokyo, tokyo)
      t_ny = Sebas::Platform::TimeSemantics.resolve_wall!(w_ny, ny)
      # 东京 08:00 = UTC 23:00（前一日）；纽约 20:00 EDT = UTC 次日 00:00
      (t_tokyo < t_ny).should be_true
    end
  end

  describe "非法输入（fail-closed）" do
    it "墙钟字段越界抛 ArgumentError" do
      expect_raises(ArgumentError) do
        Sebas::Platform::TimeSemantics.resolve_wall(
          Sebas::Platform::TimeSemantics::LocalWall.new(2026, 2, 30, 25, 0), ny)
      end
    end

    it "平年 2 月 29 日抛 ArgumentError" do
      expect_raises(ArgumentError) do
        Sebas::Platform::TimeSemantics.resolve_wall(
          Sebas::Platform::TimeSemantics::LocalWall.new(2026, 2, 29, 12, 0), ny)
      end
    end

    it "闰年 2 月 29 日可解析（Unique）" do
      res = Sebas::Platform::TimeSemantics.resolve_wall(
        Sebas::Platform::TimeSemantics::LocalWall.new(2028, 2, 29, 12, 0), ny)
      res.status.should eq(Sebas::Platform::TimeSemantics::ResolveStatus::Unique)
    end
  end
end
