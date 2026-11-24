# frozen_string_literal: true

require "json"

# 调度管理面 HTTP 路由（M4.5-WP6，自 server.cr 拆分——gzij 体量闸）：
# config.scheduling / sessions.queue / sessions.steer.get / metrics.scheduling
# 路由与辅助方法。reopen mixin（include 行在 server.cr class Server 内），
# 认证入口不变（/api/v1 外层统一闸）。
module Sebas
  module Admin
    module HTTP
      module SchedulingHTTPMethods
        # 调度路由（route 内优先调用）；命中返回 true
        def scheduling_routes(ctx : ::HTTP::Server::Context) : Bool
          case {ctx.request.method, ctx.request.path}
          when {"GET", "/api/v1/config.scheduling.get"}
            scheduling_admin_call(ctx, "config.scheduling.get", ::JSON::Any.new(Hash(String, ::JSON::Any).new))
            true
          when {"POST", "/api/v1/config.scheduling.validate"}
            code, params = body_params_with_code(ctx)
            scheduling_admin_call(ctx, "config.scheduling.validate", params, gate: code == 200)
            true # 已响应（含 413/400 拒绝），不再落 route_api
          when {"POST", "/api/v1/config.scheduling.update"}
            code, params = body_params_with_code(ctx)
            scheduling_admin_call(ctx, "config.scheduling.update", params, gate: code == 200)
            true # 已响应（含 413/400 拒绝），不再落 route_api
          when {"POST", "/api/v1/config.scheduling.reset"}
            code, params = body_params_with_code(ctx)
            scheduling_admin_call(ctx, "config.scheduling.reset", params, gate: code == 200)
            true # 已响应（含 413/400 拒绝），不再落 route_api
          when {"GET", "/api/v1/sessions.queue.get"}
            scheduling_admin_call(ctx, "sessions.queue.get", query_params_json(ctx))
            true
          when {"POST", "/api/v1/sessions.queue.flush"}
            scheduling_admin_call(ctx, "sessions.queue.flush", query_params_json(ctx))
            true
          when {"GET", "/api/v1/sessions.steer.get"}
            scheduling_admin_call(ctx, "sessions.steer.get", query_params_json(ctx))
            true
          when {"GET", "/api/v1/metrics.scheduling"}
            scheduling_admin_call(ctx, "metrics.scheduling", ::JSON::Any.new(Hash(String, ::JSON::Any).new))
            true
          else
            false
          end
        end

        # 调度管理面（M4.5-WP6）：handler 由 gateway 注入（IPC/HTTP 同一实现）
        private def query_params_json(ctx : ::HTTP::Server::Context) : ::JSON::Any
          hash = Hash(String, ::JSON::Any).new
          ctx.request.query_params.each { |key, value| hash[key] = ::JSON::Any.new(value) }
          ::JSON::Any.new(hash)
        end

        private def scheduling_admin_call(ctx : ::HTTP::Server::Context, command : String,
                                          params : ::JSON::Any, gate : Bool = true) : Nil
          handler = @scheduling_admin_handler
          unless handler
            ctx.response.status_code = 503
            ctx.response.content_type = "application/json"
            ctx.response.print(%({"error": "scheduling admin not wired"}))
            return
          end
          unless gate # 413/400 前置拒绝（itOg：超限/非法体不进 handler）
            ctx.response.content_type = "application/json"
            ctx.response.print(params.to_json)
            return
          end
          code, body = handler.call(command, params)
          ctx.response.status_code = code
          ctx.response.content_type = "application/json"
          ctx.response.print(body)
        end

        # 返回 {code, params}：code 非 200 = 拒绝（413 超限 / 400 非法体），
        # 调用方原样回写不进 handler（itOg：超限不按空对象处理）
        private def body_params_with_code(ctx : ::HTTP::Server::Context) : Tuple(Int32, ::JSON::Any)
          raw = read_limited_body(ctx) # nil = 超 1 MiB
          return {413, ::JSON::Any.new(Hash(String, ::JSON::Any).new)} if raw.nil?
          parsed = JSON.parse(raw.empty? ? "{}" : raw)
          hash = parsed.as_h?
          return {400, ::JSON::Any.new(Hash(String, ::JSON::Any).new)} unless hash
          {200, ::JSON::Any.new(hash)}
        rescue JSON::ParseException
          {400, ::JSON::Any.new(Hash(String, ::JSON::Any).new)}
        end
      end
    end
  end
end
