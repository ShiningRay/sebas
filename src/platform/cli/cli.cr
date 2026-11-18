# 命令行入口（design.md §13 platform/cli；M0-WP1 骨架）
require "log/setup"

module Sebas
  module Platform
    module CLI
      extend self

      def run(args = ARGV) : Int32
        ::Log.setup_from_env(default_sources: "sebas", default_level: :info)

        case args.first?
        when nil, "help", "--help", "-h"
          print_help
          0
        when "version", "--version", "-v"
          puts "sebas #{VERSION}"
          0
        else
          Log.error { "unknown command: #{args.first}" }
          print_help
          1
        end
      end

      private def print_help : Nil
        puts "sebas #{VERSION} - Crystal multi-account orchestratable personal agent platform"
        puts
        puts "Usage:"
        puts "  sebas help       Show this help"
        puts "  sebas version    Show version"
      end
    end
  end
end
