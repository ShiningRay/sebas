# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module SebasAgents
  # 本地运行记录：worktree 之外，原子写入，绝不保存凭据。
  #
  # v2（M4x-Parallel-WP2，#220；Proposal §5.1 + 续篇 §7 Q10=B）：
  # - 路径迁移 `.sebas-agent/run.json` → `.sebas-agent/runs/<issue>.json`，
  #   搬迁并双读一个版本：启动时自动搬迁非活动记录；活动中的 v1 记录
  #   （claiming/claimed/pr_open/merging/paused）缺 v2 字段，须人工确认，
  #   自动搬迁直接 invalid_plan（fail-closed）。
  # - `runs/` 里出现 schema 不是 2 的记录即 invalid_plan。
  # - 迁移期容量固定为 1（plan/next 的容量常量本就是 1，无需改判）。
  # - 新增字段：worker_id / coordinator_id / lease_id / scope / host /
  #   claimed_at / last_heartbeat_at。
  class RunRecord
    DEFAULT_PATH = File.join(".sebas-agent", "run.json")
    RUNS_DIR = File.join(".sebas-agent", "runs")
    SCHEMA = 2
    LEGACY_SCHEMA = 1
    FIELDS = %w[
      issue branch worktree pr base_sha phase attempts status_written label_written
      worker_id coordinator_id lease_id scope host claimed_at last_heartbeat_at
    ].freeze
    # 活动 phase（续篇 §7）：这些记录代表持有中的租约，缺 v2 字段不能自动搬。
    ACTIVE_PHASES = %w[claiming claimed pr_open merging paused].freeze

    attr_reader :path, :issue

    # path 显式给出时按调用方路径读写（测试与离线快照用）；
    # 否则按 issue 走 v2 per-issue 路径，issue 未知时回落 v1 路径（双读窗口）。
    def initialize(path: nil, issue: nil)
      @issue = issue
      @path = path || self.class.per_issue_path(issue)
      @legacy_path = DEFAULT_PATH
    end

    def self.per_issue_path(issue)
      File.join(RUNS_DIR, "#{issue}.json")
    end

    # 迁移期容量 1：runs/ 下至多一份活动记录；多份或 schema 非 2 → invalid_plan。
    # 返回活动记录 Hash 或 nil（无活动记录）。
    def self.scan_active(runs_dir = RUNS_DIR)
      return nil unless Dir.exist?(runs_dir)

      active = Dir.children(runs_dir).grep(/\.json\z/).filter_map do |file|
        path = File.join(runs_dir, file)
        data = JSON.parse(File.read(path, encoding: "UTF-8"))
        if data["schema"] != SCHEMA
          raise InvalidPlan, "runs/ 下的运行记录 schema 必须是 #{SCHEMA}：#{path}"
        end

        data if ACTIVE_PHASES.include?(data["phase"])
      end
      if active.length > 1
        raise InvalidPlan, "runs/ 下存在 #{active.length} 份活动运行记录（容量 1）：#{active.map { |r| r["issue"] }.join("、")}"
      end

      active.first
    rescue JSON::ParserError => e
      raise InvalidPlan, "运行记录不是合法 JSON（#{runs_dir}）：#{e.message}"
    end

    # 启动搬迁（Q10=B）：v1 路径存在 && v2 同卡路径不存在时搬迁。
    # 非活动记录自动搬（补 schema=2 与 v2 缺省字段）；活动记录 fail-closed
    # 要求人工确认。搬完删旧路径。v2 路径已存在时不覆盖（不吞更新）。
    # runs_dir 可注入（测试用）；生产缺省走 CWD 相对的 RUNS_DIR。
    def self.migrate_legacy!(legacy_path = DEFAULT_PATH, runs_dir: RUNS_DIR)
      return false unless File.exist?(legacy_path)

      data = JSON.parse(File.read(legacy_path, encoding: "UTF-8"))
      raise InvalidPlan, "v1 运行记录不是合法 JSON：#{legacy_path}" if data.nil?

      issue = data["issue"]
      target = issue ? File.join(runs_dir, "#{issue}.json") : nil
      if target.nil? || File.exist?(target)
        # 无 issue 的孤儿记录或同卡 v2 已在：活动态不吞更新，静默态保留待人工。
        if ACTIVE_PHASES.include?(data["phase"])
          raise InvalidPlan, "v1 活动运行记录（phase=#{data["phase"].inspect}）与既有 v2 记录并存，需人工确认后才能搬迁：#{legacy_path}"
        end
        return false
      end

      if ACTIVE_PHASES.include?(data["phase"])
        raise InvalidPlan,
          "v1 活动运行记录（phase=#{data["phase"].inspect}）缺 base_sha/lease_id/scope 等 v2 字段，" \
          "须人工确认归属后才能搬迁：请核对远端认领并手工搬至 #{target}（或删除记录重新认领）"
      end

      migrated = data.slice(*FIELDS)
        .merge("schema" => SCHEMA)
        .merge(%w[worker_id coordinator_id lease_id scope host claimed_at last_heartbeat_at]
          .filter_map { |field| [field, data[field]] unless data.key?(field) }.to_h)
      FileUtils.mkdir_p(File.dirname(target))
      temp = "#{target}.tmp"
      File.write(temp, JSON.pretty_generate(migrated), encoding: "UTF-8")
      File.rename(temp, target)
      FileUtils.rm_f(legacy_path)
      true
    rescue JSON::ParserError => e
      raise InvalidPlan, "v1 运行记录不是合法 JSON（#{legacy_path}）：#{e.message}"
    end

    # 双读（迁移窗口）：per-issue（runs/）路径强制 schema 2；显式路径与 v1
    # 遗留路径容忍 schema 1（迁移窗口内的旧记录原样可读，写入恒为 v2）。
    def load
      if File.exist?(@path)
        data = JSON.parse(File.read(@path, encoding: "UTF-8"))
        if data["schema"] != SCHEMA && File.dirname(@path) == RUNS_DIR
          raise InvalidPlan, "runs/ 下的运行记录 schema 必须是 #{SCHEMA}（got #{data["schema"].inspect}）：#{path}"
        end

        return data
      end
      return nil unless File.exist?(@legacy_path)

      JSON.parse(File.read(@legacy_path, encoding: "UTF-8"))
    rescue JSON::ParserError => e
      raise InvalidPlan, "运行记录不是合法 JSON：#{e.message}"
    end

    # 写入恒为 schema 2：路径显式指定或 issue 可知时落 per-issue 路径。
    def save(record)
      target = @path
      payload = record.slice(*FIELDS).merge("schema" => SCHEMA, "updated_at" => Time.now.utc.iso8601)
      FileUtils.mkdir_p(File.dirname(target))
      temp = "#{target}.tmp"
      File.write(temp, JSON.pretty_generate(payload), encoding: "UTF-8")
      File.rename(temp, target)
      payload
    end

    def clear
      FileUtils.rm_f(@path)
    end

    private

    def read_v2(path)
      data = JSON.parse(File.read(path, encoding: "UTF-8"))
      if data["schema"] != SCHEMA
        raise InvalidPlan, "运行记录 schema 必须是 #{SCHEMA}（got #{data["schema"].inspect}）：#{path}"
      end

      data
    rescue JSON::ParserError => e
      raise InvalidPlan, "运行记录不是合法 JSON：#{e.message}"
    end
  end
end
