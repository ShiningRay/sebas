require "json"
require "socket"
require "random"
require "../../platform/store/store"
require "../../platform/config/reload" # agents.list 读 Config::CURRENT（显式声明依赖）
require "./protocol"
require "./admin_commands"

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
        include ::Sebas::Admin::IPC::AdminCommands
        Log = Sebas::Log.for("admin.ipc")

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

        # ameba:disable Metrics/CyclomaticComplexity — 命令表分发，分支即命令本身
        private def dispatch(io : TCPSocket, frame : Frame) : Nil
          case frame.type
          when "fork", "join"
            io.puts(authenticated_response(io, frame) { fork_join_response(frame) })
          when "approvals.approve", "approvals.deny", "approvals.pending",
               "sessions.dormant", "sessions.archive", "sessions.gc", "sessions.lifecycle",
               "sessions.steer", "templates.clone", "templates.list"
            io.puts(admin_dispatch(io, frame))
          when "sessions.queue.get", "sessions.steer.get", "metrics.scheduling",
               "config.scheduling.get", "config.scheduling.validate"
            io.puts(scheduling_dispatch(io, frame)) # 读命令匿名（语义与 HTTP 一致）
          when "sessions.queue.flush", "config.scheduling.update", "config.scheduling.reset"
            io.puts(authenticated_response(io, frame) { scheduling_dispatch(io, frame) })
          when "ping"
            io.puts(ok_response(frame.id, {"pong" => JSON::Any.new(Time.utc.to_rfc3339)}))
          when "system.health"
            io.puts(ok_response(frame.id, {"status"   => JSON::Any.new("ok"),
                                           "sessions" => JSON::Any.new(@store.session_keys.size.to_i64)}))
          when "sessions.list"
            keys = @store.session_keys.map { |k| JSON::Any.new(k) }
            io.puts(ok_response(frame.id, {"sessions" => JSON::Any.new(keys)}))
          when "agents.list"
            io.puts(ok_response(frame.id, {"agents" => JSON::Any.new(agents_list_entries)}))
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

        # 写命令认证包装（CWE-306）：调用者须在 hello 里提供匹配 token——
        # 读命令维持匿名可用，写命令认证强制（CodeRabbit）。
        # 匿名可用。
        # gateway 注入 SteerCenter.submit；payload 字段名 steer（纠偏正文）
        # CWE-306 口径）；pending 清单是读命令，匿名可用。
        # 唤醒等待中的 request（Center.decide）。返回决策结果或错误原因。
        # approvals.pending：待决清单（读命令匿名可用）——id/tool/args/run/deadline

        # 返回结果 JSON）。
        def fork_handler=(handler : JSON::Any -> JSON::Any) : Nil
          @fork_handler = handler
        end

        setter steer_handler : (String, String, String?, Int64? -> ::Sebas::Sessions::Scheduling::SteerReceipt)?

        # 审批装配接线（M4.2-WP3）：approvals.approve/deny/pending 命令的处理体。
        setter approvals_center
        getter approvals_center : ::Sebas::Orchestration::Approvals::Center?

        # 会话生命周期接线（M4.4-WP4）：sessions.dormant/archive/gc 命令的处理体。
        setter lifecycle_store
        getter lifecycle_store : ::Sebas::Sessions::Lifecycle::Store?

        # 模板注册表接线（M4.4-WP4）：templates.clone/list 命令的处理体。
        setter template_registry
        setter scheduling_admin_handler : (String, ::JSON::Any -> Tuple(Int32, String))?
        getter template_registry : ::Sebas::Agents::AgentRegistry?

        # agents.list 条目（M4x-WP2，#148；提案 agent-category-tags.md §4.2）：
        # 只读无副作用，数据取自当前 Config.agents（配置真相源，不读 registry
        # 缓存——热更新后立即可见），按 id 字典序；未分类 category 输出 JSON
        # null（不是字符串 "null"）。
        private def agents_list_entries : Array(JSON::Any)
          config = ::Sebas::Platform::Config::CURRENT.get
          ids = config.agents.keys
          ids.sort!
          ids.map do |id|
            agent = config.agents[id]
            JSON::Any.new({
              "id"       => JSON::Any.new(id),
              "category" => JSON::Any.new(agent.category),
              "tags"     => JSON::Any.new(agent.tags.map { |tag| JSON::Any.new(tag) }),
            } of String => JSON::Any)
          end
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
