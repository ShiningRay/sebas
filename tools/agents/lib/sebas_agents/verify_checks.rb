# frozen_string_literal: true

require "shellwords"

module SebasAgents
  # 终验 checker：对 must_fix 条目真实复跑核验命令（#124）。
  #
  # 映射规则（卡面 #124 B）：
  #   - 条目带 evidence 且形如一条可复跑命令时，复跑该命令并比对退出码；
  #   - 无 evidence、或 evidence 不在白名单内 → {passed: false}，结论仍为打回。
  #
  # checker 不读 fix["passed"]——自报已修复不算数，只有重新执行才算。
  #
  # 执行通路不经 shell（Shellwords 解析成 argv 后走 Open3），`;`、`&&` 等
  # 组合符在 argv 语义下不会变成第二条命令。但白名单仍是第一道闸：
  # 「这比列举写命令安全——新出现的写命令默认被拦」。
  module VerifyChecks
    # 可复跑命令的执行名白名单：核验类命令，无写副作用。
    # git/gh 只放行读子命令；crystal/ruby/ameba 本身是核验工具。
    ALLOWED_BINS = %w[crystal ruby ameba shards].freeze

    GIT_READ_SUBCOMMANDS = %w[
      log describe rev-parse show diff status ls-files ls-tree cat-file
      merge-base symbolic-ref remote config blame shortlog
    ].freeze

    GH_READ_SUBCOMMANDS = %w[list view status auth search].freeze

    module_function

    def rerun(item, _fix, root: Dir.pwd)
      command = item.evidence.to_s.strip
      return {passed: false, reason: "无可复跑检查"} if command.empty?

      argv = parse(command)
      return {passed: false, reason: argv} if argv.is_a?(String) # 解析失败原因

      guard = allowed?(argv)
      return {passed: false, reason: guard} unless guard == true

      result = runner.capture(*argv, chdir: root)
      if result.success?
        {passed: true, reason: "复跑通过：#{command}"}
      else
        {passed: false, reason: "复跑失败（退出码 #{result.status&.exitstatus}）：#{command}；#{result.stderr.strip}"}
      end
    end

    def runner
      # 真跑：终验的语义就是重新执行，dry-run 在这里没有意义。
      @runner ||= CommandRunner.new(dry_run: false)
    end

    # 解析成 argv；失败返回 String 原因（有 shell 依赖或引号不闭合等）。
    def parse(command)
      Shellwords.split(command)
    rescue ArgumentError => e
      "evidence 不是可解析的单一命令：#{e.message}"
    end

    # 白名单判定；不通过返回 String 原因，通过返回 true。
    def allowed?(argv)
      bin = argv.first
      case bin
      when "git"
        return true if GIT_READ_SUBCOMMANDS.include?(argv[1])

        "git 只允许只读子命令复跑，#{argv[1].inspect} 不在白名单"
      when "gh"
        return true if gh_read_only?(argv)

        "gh 只允许只读子命令复跑，#{argv[1].inspect} 不在白名单"
      when *ALLOWED_BINS
        true
      else
        "#{bin.inspect} 不在可复跑白名单（#{ALLOWED_BINS.join("、")}，git/gh 只读子命令）"
      end
    end

    def gh_read_only?(argv)
      args = argv.drop(1)
      args = args.drop(2) while %w[-R --repo].include?(args.first)
      sub = args.first
      case sub
      when "api", "pr", "issue", "release", "repo", "run", "label", "milestone"
        # gh pr/issue/run 的 view 是读；api 默认读（写需显式 method/field）。
        # checker 场景保守起见：只认显式读子命令 view/list/status/search。
        %w[view list status search].include?(args[1])
      when "auth"
        args[1] == "status"
      else
        false
      end
    end
  end
end
