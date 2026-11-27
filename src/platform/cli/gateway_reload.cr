require "json"
require "../config/reload"

# 配置热更新触发面（#163 拆分口径：gateway.cr 行数回归闸内）：reload 命令
# 响应载荷与触发。IPC/HTTP 的 reload 入口经 `&->trigger_reload` 引用本方法。
module Sebas
  module Platform
    module CLI
      module GatewayReload
        def reload_result_payload(result : Config::ReloadResult) : Hash(String, JSON::Any)
          {
            "accepted"         => JSON::Any.new(result.accepted),
            "errors"           => JSON::Any.new(result.errors.map { |e| JSON::Any.new(e) }),
            "restart_required" => JSON::Any.new(result.restart_required.map { |e| JSON::Any.new(e) }),
          }
        end

        def trigger_reload : Hash(String, JSON::Any)
          manager = @reload_manager
          return {"accepted" => JSON::Any.new(false), "errors" => JSON::Any.new([JSON::Any.new("no config path; reload unavailable")]), "restart_required" => JSON::Any.new([] of JSON::Any)} if manager.nil?
          result = manager.reload_from_file
          reload_result_payload(result)
        end
      end
    end
  end
end
