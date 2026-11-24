require "http/server"
require "./scheduling_http"
require "json"
require "../../log"
require "../../platform/bus/bus"
require "../../channels/registry"
require "../../orchestration/runs_view"

# HTTP 管理面（M1-WP9，design.md §9.1 入口 B）：与渠道回调面共用同一监听器；
# 鉴权 token 模式（§9.1 子集，剔除 none/trusted-proxy）；SSE 事件流。
# fail-closed：未带 token 401；回调无对应 adapter 404；验签失败 401/403。
module Sebas
  module Admin
    module HTTP
      class Server
        include ::Sebas::Admin::HTTP::SchedulingHTTPMethods
        Log = Sebas::Log.for("sebas.admin.http")

        getter port : Int32
        setter lifecycle : ::Sebas::Sessions::Lifecycle::Store?
        setter templates : ::Sebas::Agents::AgentRegistry?
        setter steer_center : ::Sebas::Sessions::Scheduling::SteerCenter?
        setter hook_handler : (String, String, String? -> Tuple(Int32, String))?
        setter scheduling_admin_handler : (String, ::JSON::Any -> Tuple(Int32, String))?

        @server : ::HTTP::Server?
        @running = Atomic(Bool).new(false)

        def initialize(@channels : Channels::Registry, @tap : IPC::EventTap,
                       @bind : String = "127.0.0.1", @port : Int32 = 18790,
                       @auth_mode : String = "token", @token : String? = nil,
                       @runs_view : ::Sebas::Orchestration::RunsView? = nil,
                       @lifecycle : ::Sebas::Sessions::Lifecycle::Store? = nil,
                       @templates : ::Sebas::Agents::AgentRegistry? = nil,
                       &@on_reload : -> Hash(String, JSON::Any))
        end

        def listen : Nil
          return if @running.swap(true)
          if @auth_mode == "token" && (@token.nil? || @token.try(&.empty?))
            # fail-closed：token 模式未配置令牌 → API 不可用（回调面仍可用：回调走各平台验签）
            Log.warn { "http auth=token but no token configured; API routes disabled (callbacks still served)" }
          end
          server = ::HTTP::Server.new do |ctx|
            route(ctx)
          end
          @server = server
          address = server.bind_tcp(@bind, @port)
          @port = address.port
          spawn(name: "sebas-http") do
            server.listen
          rescue ::Exception
            nil
          end
          Log.info { "http admin listening http://#{@bind}:#{@port} (auth=#{@auth_mode})" }
        end

        def close : Nil
          @running.set(false)
          @server.try(&.close)
        end

        # hooks 请求体限读（1 MiB）；超限返回 nil 由调用方回 413
        private def read_limited_body(ctx : ::HTTP::Server::Context) : String?
          body_io = ctx.request.body
          String.build do |io|
            buffer = Bytes.new(8192)
            total = 0
            loop do
              read = body_io.try(&.read(buffer)) || 0
              break if read == 0
              total += read
              return if total > 1_048_576
              io.write(buffer[0, read])
            end
          end
        end

        private def route(ctx : ::HTTP::Server::Context) : Nil
          path = ctx.request.path
          return if scheduling_routes(ctx)
          if path.starts_with?("/hooks/") && ctx.request.method == "POST"
            # webhook 会话接入（M4.5-WP5）：hooks 入口**独立强制**管理 token
            # （不随 gateway.http.auth 配置放宽——CWE-306 fail-closed）；未知
            # hook/缺参 fail-closed，持久 admission 成功即 202 ACK
            provided = ctx.request.headers["Authorization"]?
            expected = @token.try(&.empty?) ? nil : @token
            unless expected && provided == "Bearer #{expected}"
              ctx.response.status_code = 401
              ctx.response.headers["WWW-Authenticate"] = "Bearer"
              ctx.response.print(%({"error": "unauthorized"}))
              return
            end
            handler = @hook_handler
            unless handler
              ctx.response.status_code = 503
              ctx.response.print(%({"error": "hooks not wired"}))
              return
            end
            name = path.lchop("/hooks/").split("/")[0]
            idempotency_key = ctx.request.headers["Idempotency-Key"]?
            body = read_limited_body(ctx) # 限读 1 MiB（CWE-400：超大分块不进内存）
            unless body
              ctx.response.status_code = 413
              ctx.response.print(%({"error": "payload too large"}))
              return
            end
            code, hook_body = handler.call(name, body, idempotency_key)
            ctx.response.status_code = code
            ctx.response.content_type = "application/json"
            ctx.response.print(hook_body)
            return
          end
          if path.starts_with?("/cb/")
            dispatch_callback(ctx)
            return
          end
          unless path.starts_with?("/api/v1/")
            ctx.response.status_code = 404
            ctx.response.print(%({"error": "not found"}))
            return
          end
          unless authorized?(ctx.request)
            ctx.response.status_code = 401
            ctx.response.headers["WWW-Authenticate"] = "Bearer"
            ctx.response.print(%({"error": "unauthorized"}))
            return
          end
          route_api(ctx, path)
        end

        # ameba:disable Metrics/CyclomaticComplexity — 纯路由表转发，分支即路由本身
        private def route_api(ctx : ::HTTP::Server::Context, path : String) : Nil
          case {ctx.request.method, path}
          when {"GET", "/api/v1/system.health"}
            ctx.response.content_type = "application/json"
            ctx.response.print({status: "ok"}.to_json)
          when {"GET", "/api/v1/accounts.list"}
            ctx.response.content_type = "application/json"
            ctx.response.print({accounts: @channels.all.map { |a| {channel: a.channel_type, account_id: a.account_id, health: a.health} }}.to_json)
          when {"POST", "/api/v1/config.reload"}
            ctx.response.content_type = "application/json"
            ctx.response.print(@on_reload.call.to_json)
          when {"GET", "/api/v1/runs.list"}
            ctx.response.content_type = "application/json"
            ctx.response.print({runs: @runs_view.try(&.list) || [] of JSON::Any}.to_json)
          when {"GET", "/api/v1/runs.get"}
            serve_run(ctx)
          when {"GET", "/api/v1/events"}
            serve_sse(ctx)
          when {"GET", "/api/v1/sessions.lifecycle"}
            serve_sessions_lifecycle(ctx)
          when {"POST", "/api/v1/sessions.dormant"}
            serve_sessions_dormant(ctx)
          when {"POST", "/api/v1/sessions.archive"}
            serve_sessions_archive(ctx)
          when {"POST", "/api/v1/sessions.gc"}
            serve_sessions_gc(ctx)
          when {"POST", "/api/v1/sessions.steer"}
            serve_sessions_steer(ctx)
          when {"GET", "/api/v1/templates.list"}
            ctx.response.content_type = "application/json"
            ctx.response.print({templates: @templates.try(&.disk_ids) || [] of String}.to_json)
          when {"POST", "/api/v1/templates.clone"}
            serve_template_clone(ctx)
          else
            ctx.response.status_code = 404
            ctx.response.content_type = "application/json"
            ctx.response.print(%({"error": "unknown api route"}))
          end
        end

        # 模板克隆（M4.4-WP4）：template/new_id/persona_patch 参数；未授权 401
        # 由外层统一处理（本方法仅在 authorized? 之后被调用）。
        private def serve_sessions_lifecycle(ctx : ::HTTP::Server::Context) : Nil
          ctx.response.content_type = "application/json"
          status = ctx.request.query_params["status"]?
          entries = @lifecycle.try(&.list(status)).try do |rows|
            rows.map do |entry|
              JSON::Any.new({
                "session_key"    => JSON::Any.new(entry.session_key),
                "agent_id"       => JSON::Any.new(entry.agent_id),
                "kind"           => JSON::Any.new(entry.kind),
                "status"         => JSON::Any.new(entry.status),
                "last_active_at" => JSON::Any.new(entry.last_active_at),
              }.as(Hash(String, JSON::Any)))
            end
          end
          ctx.response.print({sessions: entries || [] of JSON::Any}.to_json)
        end

        # busy steer 提交（M4.5-WP4）：session_key query + JSON body
        # {payload, target_turn_id?, target_generation?}；缺参 400，未装配 503
        # ameba:disable Metrics/CyclomaticComplexity — 参数校验直译（类型错误显式 400）
        private def serve_sessions_steer(ctx : ::HTTP::Server::Context) : Nil
          center = @steer_center
          unless center
            ctx.response.status_code = 503
            ctx.response.content_type = "application/json"
            ctx.response.print(%({"error": "steer center not wired"}))
            return
          end
          session_key = ctx.request.query_params["session_key"]?
          if session_key.nil? || session_key.empty?
            ctx.response.status_code = 400
            ctx.response.print(%({"error": "session_key is required"}))
            return
          end
          body = ctx.request.body.try(&.gets_to_end)
          params = begin
            JSON.parse(body.to_s.empty? ? "{}" : body.to_s).as_h?
          rescue JSON::ParseException
            nil
          end
          unless params
            ctx.response.status_code = 400
            ctx.response.print(%({"error": "request body must be a JSON object"}))
            return
          end
          payload = params["payload"]?.try(&.as_s?)
          unless payload
            ctx.response.status_code = 400
            ctx.response.print(%({"error": "payload is required"}))
            return
          end
          # 显式指定但类型错误 → 400（静默当未指定会错误绑定当前活跃 turn）
          target_turn_id = params["target_turn_id"]?
          if target_turn_id && target_turn_id.as_s?.nil?
            ctx.response.status_code = 400
            ctx.response.print(%({"error": "target_turn_id must be a string"}))
            return
          end
          target_generation = params["target_generation"]?
          if target_generation && target_generation.as_i64?.nil?
            ctx.response.status_code = 400
            ctx.response.print(%({"error": "target_generation must be an integer"}))
            return
          end
          target_turn_id = target_turn_id.try(&.as_s?)
          target_generation = target_generation.try(&.as_i64?)
          receipt = center.submit(session_key, payload, target_turn_id: target_turn_id,
            target_generation: target_generation)
          ctx.response.print({
            steer_id: receipt.steer_id, status: receipt.status.to_s,
            reason: receipt.reason || "", turn_id: receipt.target_turn_id,
            generation: receipt.target_generation,
          }.to_json)
        end

        # 与 IPC 同口径：older_than_days 负数/越界/非整数 400，缺省 14
        private def serve_sessions_dormant(ctx : ::HTTP::Server::Context) : Nil
          ctx.response.content_type = "application/json"
          raw = ctx.request.query_params["older_than_days"]?
          days = 14
          if raw
            parsed = raw.to_i64?
            if parsed.nil? || parsed < 0 || parsed > ::Sebas::Sessions::Lifecycle::MAX_DORMANT_DAYS
              ctx.response.status_code = 400
              ctx.response.print(%({"error": "older_than_days must be a non-negative integer"}))
              return
            end
            days = parsed.to_i32
          end
          dormant = @lifecycle.try(&.mark_dormant(days)) || [] of String
          ctx.response.print({dormant: dormant}.to_json)
        end

        private def serve_sessions_archive(ctx : ::HTTP::Server::Context) : Nil
          ctx.response.content_type = "application/json"
          key = ctx.request.query_params["session_key"]?
          if key.nil? || key.empty?
            ctx.response.status_code = 400
            ctx.response.print(%({"error": "session_key is required"}))
          elsif @lifecycle.try(&.archive(key))
            ctx.response.print({archived: key}.to_json)
          else
            ctx.response.status_code = 404
            ctx.response.print(%({"error": "session not found or already archived"}))
          end
        end

        private def serve_sessions_gc(ctx : ::HTTP::Server::Context) : Nil
          ctx.response.content_type = "application/json"
          confirm = ctx.request.query_params["confirm"]? == "true" # 人工确认闸（CWE 防误触发）
          archive_dir = ctx.request.query_params["archive_dir"]? || "archived"
          collected = @lifecycle.try(&.gc_archived(archive_dir, confirm)) || 0
          ctx.response.print({collected: collected}.to_json)
        end

        private def serve_template_clone(ctx : ::HTTP::Server::Context) : Nil
          templates = @templates
          unless templates
            ctx.response.status_code = 503
            ctx.response.content_type = "application/json"
            ctx.response.print(%({"error": "template registry not wired"}))
            return
          end
          body = ctx.request.body.try(&.gets_to_end)
          # 解析失败或根非对象 → 400（as_h 抛异常会变 500，CodeRabbit）
          params = begin
            JSON.parse(body.to_s.empty? ? "{}" : body.to_s).as_h?
          rescue JSON::ParseException
            nil
          end
          unless params
            ctx.response.status_code = 400
            ctx.response.print(%({"error": "request body must be a JSON object"}))
            return
          end
          template_id = params["template"]?.try(&.as_s?)
          new_id = params["new_id"]?.try(&.as_s?)
          patch = params["persona_patch"]?.try(&.as_s?)
          if template_id.nil? || template_id.empty? || new_id.nil? || new_id.empty?
            ctx.response.status_code = 400
            ctx.response.content_type = "application/json"
            ctx.response.print(%({"error": "template and new_id are required"}))
            return
          end
          begin
            clone = templates.clone_from_template(template_id, new_id, patch)
            ctx.response.content_type = "application/json"
            ctx.response.print({id: clone.id, persona: clone.persona[0, 200]}.to_json)
          rescue ex : ::Sebas::Agents::RegistryError
            ctx.response.status_code = 409
            ctx.response.content_type = "application/json"
            ctx.response.print(%({"error": #{ex.message.inspect}}))
          end
        end

        private def serve_run(ctx : ::HTTP::Server::Context) : Nil
          run_id = ctx.request.query_params["run_id"]? || ""
          result = @runs_view.try(&.get(run_id))
          ctx.response.content_type = "application/json"
          if result
            ctx.response.print(result.to_json)
          else
            ctx.response.status_code = 404
            ctx.response.print(%({"error": "run not found"}))
          end
        end

        private def authorized?(request : ::HTTP::Request) : Bool
          return true unless @auth_mode == "token"
          token = @token
          return false if token.nil? || token.empty? # fail-closed
          header = request.headers["Authorization"]?
          header == "Bearer #{token}"
        end

        private def dispatch_callback(ctx : ::HTTP::Server::Context) : Nil
          parts = ctx.request.path.split("/") # "", "cb", channel, account, rest...
          return unless parts.size >= 4
          adapter = @channels.find(parts[2], parts[3])
          unless adapter
            # 无对应 adapter → 404（fail-closed，Hermes 口径）
            ctx.response.status_code = 404
            ctx.response.print(%({"error": "no adapter for callback path"}))
            return
          end
          result = adapter.handle_callback(ctx.request)
          ctx.response.status_code = result.status
          ctx.response.content_type = result.content_type
          ctx.response.print(result.body)
        end

        # SSE 事件流（§9.2 events.subscribe）
        private def serve_sse(ctx : ::HTTP::Server::Context) : Nil
          ctx.response.headers["Content-Type"] = "text/event-stream"
          ctx.response.headers["Cache-Control"] = "no-cache"
          ctx.response.status_code = 200
          subscriber = Random::Secure.hex(8)
          channel = @tap.register(subscriber, capacity: 256)
          ctx.response.puts(": connected")
          ctx.response.flush
          loop do
            line = channel.receive?
            break if line.nil?
            ctx.response.puts("data: #{line}")
            ctx.response.flush
          end
        rescue ::Exception
          nil # 客户端断开
        ensure
          @tap.unregister(subscriber)
        end
      end
    end
  end
end
