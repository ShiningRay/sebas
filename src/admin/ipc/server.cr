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
            io.puts(authenticated_response(io, frame) { fork_join_response(frame) })
          when "approvals.approve", "approvals.deny", "approvals.pending",
               "sessions.dormant", "sessions.archive", "sessions.gc", "sessions.lifecycle",
               "sessions.steer", "templates.clone", "templates.list"
            io.puts(admin_dispatch(io, frame))
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

        # 写命令认证包装（CWE-306）：调用者须在 hello 里提供匹配 token——
        # 读命令维持匿名可用，写命令认证强制（CodeRabbit）。
        private def authenticated_response(io : TCPSocket, frame : Frame, &block : Frame -> String) : String
          if caller_authenticated?(io)
            block.call(frame)
          else
            error_response(frame.id, "#{frame.type} requires an authenticated hello handshake")
          end
        end

        # ameba:disable Metrics/CyclomaticComplexity — 生命周期命令表分发，分支即命令本身
        private def lifecycle_dispatch(frame : Frame) : String
          lifecycle = @lifecycle_store
          return error_response(frame.id, "#{frame.type} not available: lifecycle 组件未装配") unless lifecycle

          data = frame.data
          case frame.type
          when "sessions.lifecycle"
            status = data["status"]?.try(&.as_s?)
            entries = lifecycle.list(status).map do |entry|
              JSON::Any.new({
                "session_key"    => JSON::Any.new(entry.session_key),
                "status"         => JSON::Any.new(entry.status),
                "last_active_at" => JSON::Any.new(entry.last_active_at),
              }.as(Hash(String, JSON::Any)))
            end
            ok_response(frame.id, {"sessions" => JSON::Any.new(entries)})
          when "sessions.dormant"
            days = 14
            if raw_days = data["older_than_days"]?
              parsed = raw_days.as_i?
              # 负数 → cutoff 落在未来全误标；越界/非整数不静默回退默认（CodeRabbit）
              return error_response(frame.id, "older_than_days must be a non-negative integer") if parsed.nil? || parsed < 0 || parsed > ::Sebas::Sessions::Lifecycle::MAX_DORMANT_DAYS
              days = parsed.to_i32
            end
            dormant = lifecycle.mark_dormant(days)
            ok_response(frame.id, {"dormant" => JSON::Any.new(dormant.map { |k| JSON::Any.new(k) })})
          when "sessions.archive"
            key = data["session_key"]?.try(&.as_s?)
            return error_response(frame.id, "session_key is required") unless key
            lifecycle.archive(key) ? ok_response(frame.id, {"archived" => JSON::Any.new(key)}) : error_response(frame.id, "session not found or already archived")
          when "sessions.gc"
            confirm = data["confirm"]?.try(&.as_bool?) || false
            cleaned = lifecycle.gc_archived(data["archive_dir"]?.try(&.as_s?) || "archived", confirm)
            ok_response(frame.id, {"collected" => JSON::Any.new(cleaned.to_i64)})
          else
            error_response(frame.id, "unknown lifecycle command")
          end
        end

        private def templates_dispatch(frame : Frame) : String
          templates = @template_registry
          return error_response(frame.id, "#{frame.type} not available: template registry 未装配") unless templates

          data = frame.data
          case frame.type
          when "templates.clone"
            template_id = data["template"]?.try(&.as_s?)
            new_id = data["new_id"]?.try(&.as_s?)
            patch = data["persona_patch"]?.try(&.as_s?)
            return error_response(frame.id, "template and new_id are required") unless template_id && new_id
            begin
              clone = templates.clone_from_template(template_id, new_id, patch)
              ok_response(frame.id, {"id" => JSON::Any.new(clone.id)})
            rescue ex : ::Sebas::Agents::RegistryError
              error_response(frame.id, ex.message.to_s)
            end
          else # templates.list
            ok_response(frame.id, {"templates" => JSON::Any.new(templates.disk_ids.map { |k| JSON::Any.new(k) })})
          end
        end

        # M4.4-WP4 管理面命令路由：approvals.*（既有）/sessions 生命周期/
        # templates（本卡新增）。写命令认证强制（CWE-863 同口径）；查询读
        # 匿名可用。
        private def admin_dispatch(io : TCPSocket, frame : Frame) : String
          frame_type = frame.type
          return error_response(frame.id, "missing frame type") unless frame_type
          needs_auth = frame_type != "approvals.pending" &&
                       frame.type != "sessions.lifecycle" && frame.type != "templates.list"
          if needs_auth && !caller_authenticated?(io)
            return error_response(frame.id, "#{frame.type} requires an authenticated hello handshake")
          end
          return error_response(frame.id, "missing frame type") if frame_type.nil?
          case frame_type
          when .starts_with?("approvals.")
            approvals_dispatch(io, frame)
          when "sessions.steer"
            steer_dispatch(frame)
          when .starts_with?("sessions.")
            lifecycle_dispatch(frame)
          else # templates.*
            templates_dispatch(frame)
          end
        end

        # busy steer 提交（M4.5-WP4）：明确 correction 语义入口——handler 由
        # gateway 注入 SteerCenter.submit；payload 字段名 steer（纠偏正文）
        private def steer_dispatch(frame : Frame) : String
          handler = @steer_handler
          return error_response(frame.id, "sessions.steer not available: steer 中心未装配") unless handler
          session_key = frame.field("session_key").try(&.as_s?)
          payload = frame.field("payload").try(&.as_s?)
          return error_response(frame.id, "session_key and payload are required") unless session_key && payload
          target_turn_id = frame.field("target_turn_id").try(&.as_s?)
          target_generation = frame.field("target_generation").try(&.as_i64?)
          receipt = handler.call(session_key, payload, target_turn_id, target_generation)
          ok_response(frame.id, {
            "steer_id"   => JSON::Any.new(receipt.steer_id),
            "status"     => JSON::Any.new(receipt.status.to_s),
            "reason"     => JSON::Any.new(receipt.reason || ""),
            "turn_id"    => JSON::Any.new(receipt.target_turn_id),
            "generation" => JSON::Any.new(receipt.target_generation),
          })
        end

        # approvals 命令路由：approve/deny 是写操作（与 fork/join 同级认证，
        # CWE-306 口径）；pending 清单是读命令，匿名可用。
        private def approvals_dispatch(io : TCPSocket, frame : Frame) : String
          needs_auth = frame.type != "approvals.pending"
          if needs_auth && !caller_authenticated?(io)
            return error_response(frame.id, "#{frame.type} requires an authenticated hello handshake")
          end
          frame.type == "approvals.pending" ? approvals_pending_response(frame) : approvals_response(frame)
        end

        # approvals.approve/deny：data.id 必带，data.by 可选；决策写 memo +
        # 唤醒等待中的 request（Center.decide）。返回决策结果或错误原因。
        private def approvals_response(frame : Frame) : String
          center = @approvals_center
          return error_response(frame.id, "#{frame.type} not available: approvals 组件未装配") unless center

          id = frame.data["id"]?.try(&.as_s?)
          return error_response(frame.id, "id is required") unless id
          by = frame.data["by"]?.try(&.as_s?) || "operator"
          ok = frame.type == "approvals.approve" ? center.approve(id, by) : center.deny(id, by)
          ok ? ok_response(frame.id, {"id"       => JSON::Any.new(id),
                                      "decision" => JSON::Any.new(frame.type == "approvals.approve" ? "approved" : "denied")}) : error_response(frame.id, "no pending approval #{id}")
        end

        # approvals.pending：待决清单（读命令匿名可用）——id/tool/args/run/deadline
        private def approvals_pending_response(frame : Frame) : String
          center = @approvals_center
          return error_response(frame.id, "approvals.pending not available: approvals 组件未装配") unless center

          items = center.pending_requests.map do |req|
            JSON::Any.new({
              "id"       => JSON::Any.new(req.id),
              "tool"     => JSON::Any.new(req.tool),
              "args"     => JSON::Any.new(req.args_summary),
              "run_id"   => JSON::Any.new(req.run_id),
              "deadline" => JSON::Any.new(req.deadline.to_rfc3339),
            }.as(Hash(String, JSON::Any)))
          end
          ok_response(frame.id, {"pending" => JSON::Any.new(items)})
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

        setter steer_handler : (String, String, String?, Int64? -> ::Sebas::Sessions::Scheduling::SteerReceipt)?

        # 审批装配接线（M4.2-WP3）：approvals.approve/deny/pending 命令的处理体。
        setter approvals_center
        getter approvals_center : ::Sebas::Orchestration::Approvals::Center?

        # 会话生命周期接线（M4.4-WP4）：sessions.dormant/archive/gc 命令的处理体。
        setter lifecycle_store
        getter lifecycle_store : ::Sebas::Sessions::Lifecycle::Store?

        # 模板注册表接线（M4.4-WP4）：templates.clone/list 命令的处理体。
        setter template_registry
        getter template_registry : ::Sebas::Agents::AgentRegistry?

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
