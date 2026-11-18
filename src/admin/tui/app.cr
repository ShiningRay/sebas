require "json"
require "socket"
require "./client"
require "../ipc/protocol"

# 最小 TUI 会话面（M0-WP7）：attach 后实时观察事件流；`q` 退出。
# 审批问答（M2-WP4 双入口之一）在审批中心落地后接入本 App。
# 自写实现（termisu spike 未过预期口径，旁证 §一.8：避开 AGPL crysterm）。
module Sebas
  module Admin
    module TUI
      module App
        extend self

        def run(discovery_path : String, stdin : IO = STDIN, stdout : IO = STDOUT) : Int32
          client = Client.new(discovery_path)
          begin
            ack = client.handshake
            unless ack
              stdout.puts "handshake failed"
              return 1
            end
            stdout.puts "attached (protocol v#{IPC::VERSION}, caps: #{IPC::CAPABILITIES.join(", ")})"
            client.request("events.subscribe")

            events = Channel(String?).new(64)
            spawn do
              loop do
                line = client.read_line_raw
                events.send(line)
                break if line.nil?
              end
            rescue ::Exception
              events.send(nil)
            end

            # stdin 行 reader fiber（IO 阻塞读不能进 select，经 Channel 中转）
            keys = Channel(String?).new
            spawn do
              loop do
                line = stdin.gets
                keys.send(line.try(&.strip))
                break if line.nil?
              end
            rescue ::Exception
              keys.send(nil)
            end

            loop do
              select
              when line = events.receive?
                break if line.nil? # 服务器断开
                stdout.puts line
                stdout.flush
              when key = keys.receive?
                break if key.nil? || key == "q" || key == "quit"
              end
            end
            0
          ensure
            client.close
          end
        end
      end
    end
  end
end
