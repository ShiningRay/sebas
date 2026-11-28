# 命令行入口（design.md §13 platform/cli；M0-WP1 骨架，M0-WP8 加 gateway/crashwrite）
require "log/setup"
require "../config/paths"

module Sebas
  module Platform
    module CLI
      extend self
      Log = Sebas::Log.for("cli")

      # 日志源绑定：Sebas::Log 的源是 "sebas"，子模块经实例方法
      # Sebas::Log.for("layer") 派生为 "sebas.layer"。Log::Builder.matches 按整段
      # 前缀匹配（"sebas" 不匹配 "sebas.cli"），只绑 "sebas" 会让所有子源日志被
      # 静默丢弃——配置拒启、连接失败、健康变化一律无输出。
      DEFAULT_LOG_SOURCES = "sebas,sebas.*"

      def run(args = ARGV) : Int32
        setup_logging

        case args.first?
        when nil, "help", "--help", "-h"
          print_help
          0
        when "version", "--version", "-v"
          puts "sebas #{::Sebas.version_string}"
          0
        when "gateway"
          run_gateway(args[1..])
        when "crashwrite"
          run_crashwrite(args[1..])
        else
          Log.error { "unknown command: #{args.first}" }
          print_help
          1
        end
      end

      # 日志统一写 STDERR：正常输出（help/version）与诊断流分离，拒启原因不会被误当正文。
      # :nodoc:
      # 测试注入点：默认 STDERR；改用 sync 派发保证短命进程退出前日志已落盘。
      class_property log_io : IO = STDERR

      # :nodoc:
      # 供测试在换回 io 后重建全局绑定（只换 log_io 字段不会重绑已注册的
      # ::Log 后端——后端在 setup 时已固化，必须重新执行一次 setup）。
      def reset_logging : Nil
        setup_logging
      end

      private def setup_logging : Nil
        backend = ::Log::IOBackend.new(io: log_io, dispatcher: :sync)
        ::Log.setup_from_env(default_sources: DEFAULT_LOG_SOURCES, default_level: :info, backend: backend)
      end

      # 常驻网关（M0-WP8 装配；M5.0-WP3 路径上下文）：先构造路径上下文（home/
      # 配置文件/数据目录，sebas-home.md §2），再 fail-fast 缺配置 → 加载（配置
      # 目录作相对资源校验基准）→ 数据目录补全与告警 → Gateway 装配。
      private def run_gateway(args : Array(String)) : Int32
        explicit_config =
          begin
            arg_value(args, "--config", "-c")
          rescue ex : ArgumentError
            Log.error { ex.message.to_s }
            return 1
          end

        ctx =
          begin
            Config::PathContext.resolve(explicit_config, cwd: Path[Dir.current])
          rescue ex : Config::ConfigError
            Log.error { ex.message.to_s } # 空白 SEBAS_HOME 等解析期错误：拒启，不回退
            return 1
          end

        unless File.exists?(ctx.config_path)
          Log.error { "config not found: #{ctx.config_path}" }
          return 1
        end
        config = Config::Loader.load(ctx.config_path, config_dir: ctx.config_dir)
        ctx = ctx.with_data_dir(config.gateway.data_dir)
        ctx.warnings.each { |warning| Log.warn { warning } } # 旧布局回退 / POSIX 权限过宽
        gateway = Gateway.new(config, ctx.data_dir, ctx.config_path.to_s) do |agent, api_key|
          GatewaySecrets.default_provider(agent, api_key)
        end
        gateway.run
        sleep # 常驻
        0
      rescue ex : Config::ConfigError
        Log.error { "config rejected: #{ex.message}" } # 失败即拒启（M0-WP2 验收）
        1
      end

      # 强杀演练写入器（M0-WP8）：写 intent+task+checkpoint 后挂起，等待被 taskkill /F
      private def run_crashwrite(args : Array(String)) : Int32
        store_path = args[0]? || "crash.db"
        store = Store::Store.new(store_path)
        STDERR.puts "DBG store opened #{store.path}"
        store.record_intent("evt-crash", "message", %({"event_id": "evt-crash"}))
        task = store.create_task("turn:evt-crash", "turn", payload: %({"event_id": "evt-crash"}))
        store.checkpoint(task.id, 1)
        puts "READY"
        STDOUT.flush
        sleep 120.seconds # 等待父进程强杀
        store.close
        0
      end

      # 取 flag 的值：支持多别名（--config / -c），按声明顺序取第一个出现的。
      # 先逐个校验所有出现的别名 —— 任一缺值即报错，不允许被先命中的别名绕过
      # （`--config valid.yaml -c` 也必须报错）；「用户传了参数却静默跑另一个
      # 文件」是最误导的失败模式。
      private def arg_value(args : Array(String), *flags : String) : String?
        selected = nil
        flags.each do |flag|
          idx = args.index(flag)
          next unless idx
          value = args[idx + 1]?
          raise ArgumentError.new("option #{flag} requires a value") if value.nil? || value.starts_with?("-")
          selected ||= value
        end
        selected
      end

      private def print_help : Nil
        puts "sebas #{::Sebas.version_string} - Crystal multi-account orchestratable personal agent platform"
        puts
        puts "Usage:"
        puts "  sebas help                          Show this help"
        puts "  sebas version                       Show version"
        puts "  sebas gateway [--config config.yaml]  Run the resident gateway (-c is an alias)"
        puts "  sebas crashwrite <store-path>       Crash-drill writer (test aid)"
        puts
        puts "Home root: default ~/.sebas, overridden by SEBAS_HOME; default config <home>/config.yaml."
        puts "With no --config and no <home>/config.yaml, a legacy ./config.yaml in the startup"
        puts "directory is read with a migration warning (one-version fallback)."
      end
    end
  end
end
