# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module SebasAgents
  # 本地运行记录：worktree 之外，原子写入，绝不保存凭据。
  class RunRecord
    DEFAULT_PATH = File.join(".sebas-agent", "run.json")
    SCHEMA = 1
    FIELDS = %w[issue branch worktree pr base_sha phase attempts status_written label_written].freeze

    attr_reader :path

    def initialize(path: nil)
      @path = path || DEFAULT_PATH
    end

    def load
      return nil unless File.exist?(@path)

      data = JSON.parse(File.read(@path, encoding: "UTF-8"))
      raise InvalidPlan, "运行记录 schema 不符" unless data["schema"] == SCHEMA

      data
    rescue JSON::ParserError => e
      raise InvalidPlan, "运行记录不是合法 JSON：#{e.message}"
    end

    def save(record)
      payload = record.slice(*FIELDS).merge("schema" => SCHEMA, "updated_at" => Time.now.utc.iso8601)
      FileUtils.mkdir_p(File.dirname(@path))
      temp = "#{@path}.tmp"
      File.write(temp, JSON.pretty_generate(payload), encoding: "UTF-8")
      File.rename(temp, @path)
      payload
    end

    def clear
      FileUtils.rm_f(@path)
    end
  end
end
