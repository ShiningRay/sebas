# frozen_string_literal: true

require "json"
require "optparse"

module SebasAgents
  # JSON 输出与退出码：0 允许 / 1 门禁拒绝 / 2 用法或环境错误。
  module Output
    module_function

    def emit(payload, out: $stdout)
      out.puts(JSON.pretty_generate(payload))
    end

    def error(message, code: "usage_error", out: $stderr)
      out.puts(JSON.pretty_generate({"ok" => false, "error" => {"code" => code, "message" => message}}))
    end
  end

  # 语法糖：把 ARGV 解析成 options + positional。
  module Argv
    module_function

    def parse(argv, required: [], optional: 0)
      options = {}
      positional = []
      parser = OptionParser.new do |opts|
        opts.on("--repo OWNER/NAME") { |value| options[:repo] = value }
        opts.on("--root PATH") { |value| options[:root] = value }
        opts.on("--snapshot PATH") { |value| options[:snapshot] = value }
        opts.on("--record PATH") { |value| options[:record] = value }
        opts.on("--fixes PATH") { |value| options[:fixes] = value }
        opts.on("--report PATH") { |value| options[:report] = value }
        opts.on("--verdict PATH") { |value| options[:verdict] = value }
        opts.on("--apply") { options[:apply] = true }
        opts.on("--dry-run") { options[:apply] = false }
        # 合并前自检：跳过「已合并 / 已关闭」这两条只有合并后才可能成立的条件。
        opts.on("--pre") { options[:pre] = true }
        # 终验（#124）：基于核验报告对 must_fix 逐项复跑 checker，产出终验结论。
        opts.on("--final") { options[:final] = true }
        opts.on("--help", "-h") { options[:help] = true }
      end

      rest = parser.parse(argv)
      positional = rest.reject { |item| item.start_with?("-") }

      # --help 不产生任何副作用：直接交给调用方打印帮助。
      return [options.merge(help: true), positional] if options[:help]

      if positional.length < required.length || positional.length > required.length + optional
        expected = (required + ["[...]"] * optional).join(" ")
        raise UsageError, "参数数量不符：期望 #{expected}，实际 #{positional.join(" ").inspect}"
      end

      [options, positional]
    rescue OptionParser::ParseError => e
      raise UsageError, e.message
    end
  end
end
