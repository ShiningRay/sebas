require "json"
require "socket"
require "random"
require "../../platform/store/store"
require "./protocol"

# 事件广播（M0-WP7）：bus → 多订阅者扇出；订阅者队列有界，满则丢弃（TUI 只读视图可容忍，
# 不反压总线主链路）。
module Sebas
  module Admin
    module IPC
      class EventTap
        @subs = Hash(String, Channel(String)).new
        @mutex = Mutex.new

        def register(subscriber_id : String, capacity : Int32 = 128) : Channel(String)
          @mutex.synchronize do
            channel = Channel(String).new(capacity)
            @subs[subscriber_id] = channel
            channel
          end
        end

        def unregister(subscriber_id : String?) : Nil
          return unless id = subscriber_id
          @mutex.synchronize do
            channel = @subs.delete(id)
            channel.try(&.close)
          end
        end

        def publish(line : String) : Nil
          @mutex.synchronize do
            @subs.each_value do |channel|
              # 满则丢弃（视图可容忍）：非阻塞发送经 select + timeout 0 实现
              select
              when channel.send(line)
              when timeout 0.seconds
              end
            end
          end
        end

        def subscriber_count : Int32
          @mutex.synchronize { @subs.size }
        end
      end

      # 事件行编码：统一 type 前缀（events.* 由管理面契约 §9.2 划分）
      def self.event_line(kind : String, payload : Hash(String, JSON::Any) = {} of String => JSON::Any) : String
        {type: "event.#{kind}", ts: Time.utc.to_rfc3339, payload: payload}.to_json
      end
    end
  end
end

module Sebas
  module Admin
    module IPC
      class Server
        Log = Sebas::Log.for("sebas.admin.ipc")

        getter token : String
        getter port : Int32
        getter discovery_path : Path

        @tap = EventTap.new
        @server : TCPServer?
        @running = Atomic(Bool).new(false)

        # fork/join 触发面（M4.1-WP5，Q3：用户显式命令，不动生产 agent_turn）；
        # nil 时 fork/join 命令回 not available（gateway 未装配 fork 组件的旧链路）。
        @fork_handler : (JSON::Any -> JSON::Any)?
        # 已认证连接（hello token 匹配）——持有 socket 引用本身（防 object_id
        # 内存地址复用导致匿名连接继承认证，CWE-613），连接结束即撤销。
        @authenticated_connections = Set(TCPSocket).new

        def initialize(@store : Platform::Store::Store, data_dir : Path,
                       @host : String = "127.0.0.1", @port : Int32 = DEFAULT_PORT,
                       @token : String = Random::Secure.hex(16),
                       @runs_view : ::Sebas::Orchestration::RunsView? = nil,
                       &@on_reload : -> Hash(String, JSON::Any))
          # IPC 明文 TCP（CWE-319）：仅允许回环绑定——远程部署须经认证加密传输
          # （TLS 另卡），否则可观察链路的攻击者可截获可复用 token。
          unless {"127.0.0.1", "::1", "localhost"}.includes?(@host)
            raise ArgumentError.new("IPC host 必须为回环地址（127.0.0.1/::1/localhost），实际：#{@host}；远程 IPC 需加密传输（另卡）")
          end
          discovery_dir = data_dir / "ipc"
          Dir.mkdir_p(discovery_dir)
          @discovery_path = discovery_dir / "discovery.json"
          write_discovery("tcp", @host, @port)
        end

        def listen : Nil
          return if @running.swap(true)
          @server = TCPServer.new(@host, @port)
          bound = @server
          return unless bound              # 服务器句柄缺失
          @port = bound.local_address.port # 端口 0 = 随机端口，回写 discovery
          write_discovery("tcp", @host, @port)
          spawn do
            while @running.get
              begin
                listener = @server
                break unless listener
                client = listener.accept
              rescue ::Exception
                break
              end
              spawn handle_client(client)
            end
          end
          Log.info { "ipc server listening tcp://#{@host}:#{@port} (discovery: #{@discovery_path})" }
        end

        def close : Nil
          @running.set(false)
          @server.try(&.close)
          File.delete(@discovery_path) if File.exists?(@discovery_path)
        end

        def tap : EventTap
          @tap
        end

        private def write_discovery(transport : String, host : String, port : Int32) : Nil
          File.write(@discovery_path, {
            protocol: PROTOCOL, version: VERSION, transport: transport,
            host: host, port: port, token: @token,
          }.to_json)
        end

        # 客户端处理：握手 → 读帧 fiber + 事件扇出 select → 命令分派
        private def handle_client(io : TCPSocket) : Nil
          io.sync = true
          hello = handshake(io)
          return unless hello
          mark_authenticated(io, hello)
          # 握手后的清理作用域覆盖认证后的首次响应（hello_ack 写失败也撤销
          # 认证，CodeRabbit CWE-613 补充）：begin 从此处开始到连接结束。
          begin
            io.puts({type: "hello_ack", protocol: PROTOCOL, version: VERSION, caps: CAPABILITIES}.to_json)
            subscriber_id = Random::Secure.hex(8)

            frames = Channel(Frame?).new
            spawn do
              # 读帧 fiber：socket 断开/关闭时异常必须就地消化，否则炸进程
              loop do
                begin
                  frame = read_frame(io)
                rescue ::Exception
                  frame = nil
                end
                frames.send(frame)
                break if frame.nil?
              end
            end
            if hello.caps.includes?("events.subscribe")
              events = @tap.register(subscriber_id)
              loop do
                select
                when frame = frames.receive
                  break if frame.nil?
                  dispatch(io, frame)
                when line = events.receive?
                  io.puts(line) if line
                end
              end
            else
              loop do
                frame = frames.receive
                break if frame.nil?
                dispatch(io, frame)
              end
            end
          ensure
            # 连接结束（正常/异常）即撤销认证——认证绑定 socket 本身，
            # object_id 可被 GC 后的新连接复用（CWE-613）
            @authenticated_connections.delete(io)
            @tap.unregister(subscriber_id)
            io.close rescue nil
          end
        end

        # 握手：首帧必须为合法 hello；失败回错误并断开
        private def handshake(io : TCPSocket) : Hello?
          line = read_line(io)
          unless line
            io.close
            return
          end
          hello = begin
            Hello.parse(JSON.parse(line))
          rescue JSON::ParseException
            nil # 非 JSON 首帧 → 握手失败
          end
          unless hello
            io.puts({type: "error", error: "handshake required: #{PROTOCOL} v#{VERSION}"}.to_json)
            io.close
          end
          hello
        end

        private def dispatch(io : TCPSocket, frame : Frame) : Nil
          case frame.type
          when "fork", "join"
            # 写触发命令（CWE-306）：调用者必须在 hello 里提供匹配 token——
            # 读命令维持匿名可用，写命令认证强制（CodeRabbit）。
            if caller_authenticated?(io)
              io.puts(fork_join_response(frame))
            else
              io.puts(error_response(frame.id, "fork/join requires an authenticated hello handshake"))
            end
          when "ping"
            io.puts(ok_response(frame.id, {"pong" => JSON::Any.new(Time.utc.to_rfc3339)}))
          when "system.health"
            io.puts(ok_response(frame.id, {"status"   => JSON::Any.new("ok"),
                                           "sessions" => JSON::Any.new(@store.session_keys.size.to_i64)}))
          when "sessions.list"
            keys = @store.session_keys.map { |k| JSON::Any.new(k) }
            io.puts(ok_response(frame.id, {"sessions" => JSON::Any.new(keys)}))
          when "sessions.read"
            key = frame.field("session_key").try(&.as_s?) || ""
            rows = @store.transcripts(key).map do |row|
              JSON::Any.new({created_at: row.created_at, role: row.role, content: row.content}.to_json)
            end
            io.puts(ok_response(frame.id, {"entries" => JSON::Any.new(rows)}))
          when "events.subscribe"
            io.puts(ok_response(frame.id, {"subscribed" => JSON::Any.new(true)}))
          when "config.status"
            io.puts(ok_response(frame.id, {"reload" => JSON::Any.new("config.reload command available")}))
          when "config.reload"
            result = @on_reload.call
            io.puts(ok_response(frame.id, result))
          when "runs.list", "runs.get"
            io.puts(runs_response(frame))
          else
            io.puts(error_response(frame.id, "unknown command: #{frame.type}"))
          end
        end

        private def fork_join_response(frame : Frame) : String
          handler = @fork_handler
          return error_response(frame.id, "#{frame.type} not available: fork 组件未装配") unless handler

          begin
            result = handler.call(JSON::Any.new(frame.data))
            ok_response(frame.id, {"result" => result})
          rescue ex : ::Sebas::Platform::Store::StoreError
            # 校验异常（缺 task / 缺 main agent 配置）转错误响应——保留连接，
            # 客户端拿到该请求的失败原因而非断连（CodeRabbit）
            error_response(frame.id, ex.message.to_s)
          end
        end

        # 注册 fork/join 命令处理器（gateway 装配后接线；handler 收 IPC 帧数据
        # 返回结果 JSON）。
        def fork_handler=(handler : JSON::Any -> JSON::Any) : Nil
          @fork_handler = handler
        end

        # token 匹配则本连接视为已认证（写命令 fork/join 的前置条件）。
        # 认证绑定 socket 引用本身（非 object_id——内存地址可复用）。
        private def mark_authenticated(io : TCPSocket, hello : Hello) : Nil
          @authenticated_connections.add(io) if hello.token == @token
        end

        # 调用者认证：fork/join 写命令前置条件，普通读命令匿名可用。
        private def caller_authenticated?(io : TCPSocket) : Bool
          @authenticated_connections.includes?(io)
        end

        private def runs_response(frame : Frame) : String
          if frame.type == "runs.list"
            runs = @runs_view.try(&.list) || [] of JSON::Any
            return ok_response(frame.id, {"runs" => JSON::Any.new(runs)})
          end
          run_id = frame.field("run_id").try(&.as_s?) || ""
          result = @runs_view.try(&.get(run_id))
          result ? ok_response(frame.id, result) : error_response(frame.id, "run not found")
        end

        private def ok_response(id : String?, payload : Hash(String, JSON::Any)) : String
          IPC.ok(id, payload)
        end

        private def error_response(id : String?, message : String) : String
          IPC.error(id, message)
        end

        private def read_line(io : TCPSocket) : String?
          line = io.gets
          return if line.nil?
          line.chomp
        end

        # 断开/坏帧（8MiB 超限）返回 nil
        private def read_frame(io : TCPSocket) : Frame?
          line = read_line(io)
          return if line.nil?
          Frame.parse(line)
        end
      end
    end
  end
end
