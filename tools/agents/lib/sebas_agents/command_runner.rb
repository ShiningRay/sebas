# frozen_string_literal: true

require "json"
require "open3"

module SebasAgents
  # gh / git 适配器。所有副作用集中在这里。
  #
  # dry-run 采用**白名单**：只有明确认定为只读的命令才真的执行，其余一律不执行。
  # 这比「列举写命令」安全——新出现的写命令默认被拦，而不是默认放行。
  class CommandRunner
    Result = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
      def success?
        status&.success? || false
      end
    end

    attr_reader :calls

    # `gh api` 只读：判定依据是「未显式声明写方法，且未用隐含 POST 的字段参数」。
    API_FIELD_FLAGS = %w[-f -F --field --raw-field].freeze

    def initialize(dry_run: true)
      @dry_run = dry_run
      @calls = []
      @allowed_write = nil
    end

    def dry_run?
      @dry_run
    end

    # 显式授权一个写意图（例如认领标签）。仅影响下一次 capture，
    # 避免"放开 dry_run 就等于全局可写"。
    def with_write(intent)
      @allowed_write = intent
      yield
    ensure
      @allowed_write = nil
    end

    def capture(*argv, chdir: Dir.pwd, stdin: nil)
      @calls << argv
      if @dry_run && !read_only?(argv) && !allowed_write?(argv)
        return Result.new(stdout: "", stderr: "", status: FakeStatus.new(true))
      end

      options = {chdir: chdir}
      options[:stdin_data] = stdin if stdin
      with_retry do
        stdout, stderr, status = Open3.capture3(*argv, **options)
        Result.new(stdout: stdout, stderr: stderr, status: status)
      end
    rescue Errno::ENOENT => e
      raise CommandError.new("命令不存在：#{argv.first}（#{e.message}）", command: argv)
    end

    # 网络瞬断（EOF / 502 / 503 / timeout）重试一次；鉴权与 404 不重试。
    # 重试耗尽时返回最后一次失败结果（而不是抛异常），让 run! 统一补上
    # command / stderr 上下文——否则上层拿到的是没有出处的错误。
    RETRYABLE = /EOF|502|503|timed out|timeout/i
    def with_retry
      attempts = 0
      loop do
        attempts += 1
        result = yield
        return result unless !result.success? && result.stderr.match?(RETRYABLE)
        return result if attempts >= 2

        sleep(1 + attempts)
      end
    end

    def run!(*argv, chdir: Dir.pwd)
      result = capture(*argv, chdir: chdir)
      return result.stdout if result.success?

      raise CommandError.new(
        "命令失败：#{argv.join(" ")}\n#{result.stderr.strip}",
        command: argv, stderr: result.stderr
      )
    end

    def json!(*argv, chdir: Dir.pwd)
      output = run!(*argv, chdir: chdir)
      JSON.parse(output)
    rescue JSON::ParserError => e
      raise CommandError.new("JSON 解析失败：#{argv.join(" ")}（#{e.message}）", command: argv)
    end

    GIT_READ_SUBCOMMANDS = %w[
      log describe rev-parse show diff status ls-files ls-tree cat-file
      merge-base symbolic-ref remote config blame shortlog
    ].freeze

    GH_READ_SUBCOMMANDS = %w[list view status auth search].freeze

    private

    def read_only?(argv)
      return read_only_git?(argv) if argv.first == "git"
      return read_only_gh?(argv) if argv.first == "gh"

      false
    end

    # 只放行与授权意图完全匹配的单一命令形态，其余写命令仍被拦截。
    ALLOWED_WRITES = {
      add_label: /\Agh\s+issue\s+edit\s+\d+\s+--repo\s+\S+\s+--add-label\s+\S+\z/,
      remove_label: /\Agh\s+issue\s+edit\s+\d+\s+--repo\s+\S+\s+--remove-label\s+\S+\z/
    }.freeze

    def allowed_write?(argv)
      return false if @allowed_write.nil?

      pattern = ALLOWED_WRITES[@allowed_write]
      !pattern.nil? && pattern.match?(argv.join(" "))
    end

    def read_only_git?(argv)
      args = skip_global_options(argv.drop(1))
      return false if args.empty?

      GIT_READ_SUBCOMMANDS.include?(args.first)
    end

    # 跳过 -C <dir>、--git-dir x、-c key=val 等前置选项。
    def skip_global_options(args)
      rest = args.dup
      loop do
        case rest.first
        when "-C", "--git-dir", "--work-tree", "-c"
          rest = rest.drop(2)
        when /\A--(?:git-dir|work-tree)=/, /\A-[cC]/
          rest = rest.drop(1)
        else
          return rest
        end
      end
    end

    def read_only_gh?(argv)
      args = argv.drop(1)
      args = args.drop(2) while %w[-R --repo].include?(args.first)

      subcommand = args.first
      return false if subcommand.nil?

      return api_read_only?(args.drop(1)) if subcommand == "api"

      # gh pr / gh issue / gh checkout 等的读子命令
      if %w[pr issue].include?(subcommand)
        return GH_READ_SUBCOMMANDS.include?(args[1])
      end
      return args[1] == "view" if subcommand == "release"
      return %w[view list].include?(args[1]) if %w[repo label milestone].include?(subcommand)
      return true if subcommand == "status"
      return true if subcommand == "auth" && args[1] == "status"

      false
    end

    # gh api：默认只读；以下任一出现即为写：
    #   - 显式 -X/--method 不是 GET
    #   - 使用 -f/-F/--field/--raw-field（隐含 POST）
    #   - 使用 --input（请求体）
    # 例外：graphql 的 -f 只是查询变量，仍属只读。
    def api_read_only?(args)
      method = api_method(args)
      return false if args.include?("--input")
      return true if method == "GET"
      return false if method

      if args.first == "graphql"
        # graphql 必须用 POST，但本工具有意只允许其查询变量形式；-f 在此不构成写。
        return true
      end

      !api_field_flags?(args)
    end

    def api_method(args)
      args.each_with_index.filter_map do |arg, index|
        if %w[-X --method].include?(arg)
          args[index + 1].to_s.upcase
        elsif arg.start_with?("--method=")
          arg.split("=", 2).last.to_s.upcase
        end
      end.first
    end

    def api_field_flags?(args)
      API_FIELD_FLAGS.any? do |flag|
        args.include?(flag) ||
          args.any? { |arg| arg.start_with?("#{flag}=") } ||
          (flag.length == 2 && args.any? { |arg| arg.match?(/\A#{Regexp.escape(flag)}\S/) })
      end
    end

    FakeStatus = Struct.new(:success?) do
      def initialize(value)
        super(value)
      end
    end
  end
end
