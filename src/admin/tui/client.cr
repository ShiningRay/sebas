require "json"
require "socket"
require "../ipc/protocol"

# TUI 客户端（M0-WP7，自写最小 TUI——termisu 36★ 活跃度存疑 spike 未过预期口径）：
# 读 discovery.json 连入 IPC server，hello 握手，事件订阅 + 命令请求。
# 终端交互层（会话流实时渲染/审批问答）在 app.cr。
module Sebas
  module Admin
    module TUI
      class Client
        getter? protocol_ok : Bool

        def initialize(discovery_path : String | Path, @read_timeout : Time::Span = 10.seconds)
          meta = JSON.parse(File.read(discovery_path))
          raise ::Exception.new("discovery protocol mismatch") unless meta["protocol"].as_s == IPC::PROTOCOL
          @io = TCPSocket.new(meta["host"].as_s, meta["port"].as_i)
          @io.sync = true
          @io.write_timeout = @read_timeout
          @io.read_timeout = @read_timeout
          @protocol_ok = false
        end

        # hello 握手；caps 协商
        def handshake(caps : Array(String) = IPC::CAPABILITIES) : Hash(String, JSON::Any)?
          @io.puts(IPC::Hello.new(IPC::PROTOCOL, IPC::VERSION, caps).to_frame)
          frame = read_response do |data|
            data["type"]?.try(&.as_s?) == "hello_ack"
          end
          @protocol_ok = !frame.nil?
          frame
        end

        def request(type : String, payload : Hash(String, JSON::Any) = {} of String => JSON::Any,
                    id : String = Random::Secure.hex(6)) : Hash(String, JSON::Any)?
          body = {"type" => JSON::Any.new(type), "id" => JSON::Any.new(id)}
          payload.each { |k, v| body[k] = v }
          @io.puts(JSON::Any.new(body).to_json)
          read_response { |data| data["id"]?.try(&.as_s?) == id }
        end

        # 读到谓词命中的帧；事件行经 on_event 回调
        def read_response(timeout : Time::Span = @read_timeout, &match : Hash(String, JSON::Any) -> Bool) : Hash(String, JSON::Any)?
          deadline = Time.instant + timeout
          while Time.instant < deadline
            line = @io.gets
            return if line.nil?
            data = JSON.parse(line).as_h?
            next unless data
            return data if match.call(data)
          end
          nil
        rescue IO::TimeoutError
          nil
        end

        # 原始行读取（事件流渲染用）；断开/超时返回 nil
        def read_line_raw : String?
          line = @io.gets
          return if line.nil?
          line.chomp
        rescue ::Exception
          nil
        end

        def close : Nil
          @io.close
        rescue ::Exception
          nil
        end
      end
    end
  end
end
