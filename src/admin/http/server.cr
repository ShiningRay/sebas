require "http/server"
require "json"
require "../../log"
require "../../platform/bus/bus"
require "../../channels/registry"

# HTTP 管理面（M1-WP9，design.md §9.1 入口 B）：与渠道回调面共用同一监听器；
# 鉴权 token 模式（§9.1 子集，剔除 none/trusted-proxy）；SSE 事件流。
# fail-closed：未带 token 401；回调无对应 adapter 404；验签失败 401/403。
module Sebas
  module Admin
    module HTTP
      class Server
        Log = Sebas::Log.for("sebas.admin.http")

        getter port : Int32

        @server : ::HTTP::Server?
        @running = Atomic(Bool).new(false)

        def initialize(@channels : Channels::Registry, @tap : IPC::EventTap,
                       @bind : String = "127.0.0.1", @port : Int32 = 18790,
                       @auth_mode : String = "token", @token : String? = nil,
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

        private def route(ctx : ::HTTP::Server::Context) : Nil
          path = ctx.request.path
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
          when {"GET", "/api/v1/events"}
            serve_sse(ctx)
          else
            ctx.response.status_code = 404
            ctx.response.content_type = "application/json"
            ctx.response.print(%({"error": "unknown api route"}))
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
