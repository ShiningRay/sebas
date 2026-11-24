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
            scheduling_admin_call(ctx, "config.scheduling.validate", body_params_json(ctx))
            true
          when {"POST", "/api/v1/config.scheduling.update"}
            scheduling_admin_call(ctx, "config.scheduling.update", body_params_json(ctx))
            true
          when {"POST", "/api/v1/config.scheduling.reset"}
            scheduling_admin_call(ctx, "config.scheduling.reset", body_params_json(ctx))
            true
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
                                          params : ::JSON::Any? = nil) : Nil
          handler = @scheduling_admin_handler
          unless handler
            ctx.response.status_code = 503
            ctx.response.content_type = "application/json"
            ctx.response.print(%({"error": "scheduling admin not wired"}))
            return
          end
          unless params
            ctx.response.status_code = 400
            ctx.response.content_type = "application/json"
            ctx.response.print(%({"error": "request body must be a JSON object"}))
            return
          end
          code, body = handler.call(command, params)
          ctx.response.status_code = code
          ctx.response.content_type = "application/json"
          ctx.response.print(body)
        end

        # 请求体 → JSON params（gzis）：空体 = 空对象（缺参走 handler 校验），
        # 非法 JSON/非对象 → nil（scheduling_admin_call 回 400）
        private def body_params_json(ctx : ::HTTP::Server::Context) : ::JSON::Any
          raw = read_limited_body(ctx).to_s
          parsed = JSON.parse(raw.empty? ? "{}" : raw)
          parsed.as_h?.try { |h| ::JSON::Any.new(h) } || ::JSON::Any.new(Hash(String, ::JSON::Any).new)
        rescue
          ::JSON::Any.new(Hash(String, ::JSON::Any).new)
        end
      end
    end
  end
end
