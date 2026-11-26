# 命令行入口（design.md §13 platform/cli；M0-WP1 骨架，M0-WP8 加 gateway/crashwrite）
require "log/setup"

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
          puts "sebas #{VERSION}"
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

      # 日志统一写 STDERR：正常输出（help/version）与诊断流分离，拒启原因不会被误当正文
      private def setup_logging : Nil
        backend = ::Log::IOBackend.new(io: STDERR)
        ::Log.setup_from_env(default_sources: DEFAULT_LOG_SOURCES, default_level: :info, backend: backend)
      end

      # 常驻网关（M0-WP8 装配）：加载配置 → Gateway#run → 常驻
      private def run_gateway(args : Array(String)) : Int32
        config_path =
          begin
            arg_value(args, "--config", "-c") || "config.yaml"
          rescue ex : ArgumentError
            Log.error { ex.message.to_s }
            return 1
          end
        unless File.exists?(config_path)
          Log.error { "config not found: #{config_path}" }
          return 1
        end
        config = Config::Loader.load(config_path)
        data_dir = Path[Path[config_path].parent, config.gateway.data_dir]
        gateway = Gateway.new(config, data_dir, config_path) do |agent, api_key|
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

      # 取 flag 的值：支持多别名（--config / -c），先匹配先得。
      # 只认「flag 后跟非 flag 值」形态——避免把下一个 flag 误当路径；缺值即报错，
      # 不静默回退到默认 config.yaml（用户传了参数却跑另一个文件最误导）。
      private def arg_value(args : Array(String), *flags : String) : String?
        flags.each do |flag|
          idx = args.index(flag)
          next unless idx
          value = args[idx + 1]?
          return value if value && !value.starts_with?("-")
          raise ArgumentError.new("option #{flag} requires a value")
        end
        nil
      end

      private def print_help : Nil
        puts "sebas #{VERSION} - Crystal multi-account orchestratable personal agent platform"
        puts
        puts "Usage:"
        puts "  sebas help                          Show this help"
        puts "  sebas version                       Show version"
        puts "  sebas gateway --config config.yaml  Run the resident gateway (-c is an alias)"
        puts "  sebas crashwrite <store-path>       Crash-drill writer (test aid)"
      end
    end
  end
end
