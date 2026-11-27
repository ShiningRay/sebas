require "json"

# 插件协议（M3-WP4，#16；design.md §12.2）：有长度上限的 NDJSON 请求/结果。
#
# 通道拓扑（宿主 runner ⇄ 裁剪 mruby 子进程）：
# - 程序：合成脚本（prelude + plugin.rb）经 argv 传给解释器；
# - stdin：单行 request（JSON）+ 执行期的 capability_result 应答帧；
# - stdout：`registered` 帧（注册集报告）→ 0..n 个 `capability_call` 帧 →
#   恰好一个 `result` 帧，其后不允许任何输出；
# - stderr：受限诊断（截断保存）。
#
# 字段闭集纪律：每类帧只接受声明字段，未知字段一律拒绝（不做静默忽略）。
module Sebas
  module Plugins
    class ProtocolError < ::Exception; end

    module Protocol
      PROTOCOL_VERSION = 1

      # 单帧上限（含 request 行与全部 stdout 帧）
      MAX_FRAME        = 1_048_576       # 1 MiB
      MAX_STDOUT_TOTAL = 8 * 1024 * 1024 # 8 MiB
      # 单次调用 host-call 次数上限（§12.2 host-call 语义；WP5 引入
      # manifest/全局较小者口径前先取宿主常量）
      MAX_CAPABILITY_CALLS =   64
      MAX_STDERR           = 4096

      record Request,
        request_id : String,
        plugin_id : String,
        action : String,
        context : JSON::Any,
        payload : JSON::Any,
        config : JSON::Any,
        idempotency_key : String? do
        def to_frame : String
          frame = {
            "protocol_version" => JSON::Any.new(PROTOCOL_VERSION),
            "request_id"       => JSON::Any.new(request_id),
            "plugin_id"        => JSON::Any.new(plugin_id),
            "action"           => JSON::Any.new(action),
            "context"          => context,
            "payload"          => payload,
            "config"           => config,
          } of String => JSON::Any
          frame["idempotency_key"] = JSON::Any.new(idempotency_key) if idempotency_key
          frame.to_json
        end
      end

      # stdout 帧解析结果：registered / capability_call / result 三类。
      # 解析即校验：类型未知、字段缺失/多余、类型不符、超限都返回错误。
      abstract struct Frame; end

      struct RegisteredFrame < Frame
        getter actions : Array(String)
        getter hooks : Array(String)

        def initialize(@actions, @hooks)
        end
      end

      struct CapabilityCallFrame < Frame
        getter call_id : String
        getter capability : String
        # params 允许 null（JSON-like 三态：对象/数组/null）
        getter params : JSON::Any?

        def initialize(@call_id, @capability, @params)
        end
      end

      struct ResultFrame < Frame
        getter request_id : String
        getter value : JSON::Any?
        getter error_code : String?
        getter error_message : String?
        @ok : Bool

        def initialize(@request_id, @ok, @value, @error_code, @error_message)
        end

        def ok? : Bool
          @ok
        end
      end

      # 解析并校验一帧。line 已去除换行；超限由调用方按 MAX_FRAME 预检。
      # ameba:disable Metrics/CyclomaticComplexity — 帧类型分支即协议闭集校验本身
      def self.parse_frame(line : String) : Frame
        if line.bytesize > MAX_FRAME
          raise ProtocolError.new("frame exceeds #{MAX_FRAME} bytes")
        end
        obj = begin
          JSON.parse(line).as_h?
        rescue JSON::ParseException
          nil
        end
        raise ProtocolError.new("stdout line is not a JSON object frame") unless obj
        type = obj["type"]?.try(&.as_s?)
        raise ProtocolError.new("frame missing 'type'") unless type
        case type
        when "registered"
          require_fields(obj, {"type", "actions", "hooks"}, "registered")
          reject_unknown(obj, {"type", "actions", "hooks"}, "registered")
          RegisteredFrame.new(string_array(obj["actions"]?, "actions"),
            string_array(obj["hooks"]?, "hooks"))
        when "capability_call"
          require_fields(obj, {"type", "call_id", "capability", "params"}, "capability_call")
          reject_unknown(obj, {"type", "call_id", "capability", "params"}, "capability_call")
          call_id = obj["call_id"]?.try(&.as_s?)
          capability = obj["capability"]?.try(&.as_s?)
          raise ProtocolError.new("capability_call.call_id must be a string") unless call_id
          raise ProtocolError.new("capability_call.capability must be a string") unless capability
          params = obj["params"]?
          unless params.nil? || params.as_h? || params.as_a?
            raise ProtocolError.new("capability_call.params must be an object/array/null")
          end
          CapabilityCallFrame.new(call_id, capability, params)
        when "result"
          require_fields(obj, {"type", "request_id", "ok"}, "result")
          reject_unknown(obj, {"type", "request_id", "ok", "value", "error"}, "result")
          request_id = obj["request_id"]?.try(&.as_s?)
          raise ProtocolError.new("result.request_id must be a string") unless request_id
          ok = obj["ok"]?.try(&.as_bool?)
          raise ProtocolError.new("result.ok must be a boolean") unless ok.is_a?(Bool)
          if ok
            reject_unknown(obj, {"type", "request_id", "ok", "value"}, "result(ok)")
            ResultFrame.new(request_id, true, obj["value"]?, nil, nil)
          else
            error = obj["error"]?.try(&.as_h?)
            raise ProtocolError.new("result(ok=false) must carry an error object") unless error
            code = error["code"]?.try(&.as_s?)
            raise ProtocolError.new("result.error.code must be a string") unless code
            message = error["message"]?.try(&.as_s?) || ""
            ResultFrame.new(request_id, false, nil, code, message)
          end
        else
          raise ProtocolError.new("unknown frame type: #{type}")
        end
      end

      # capability_result 应答帧（宿主 → 插件 stdin）。
      def self.capability_result(call_id : String, ok : Bool,
                                 result : JSON::Any?, error_code : String?, error_message : String?) : String
        payload = {"type" => JSON::Any.new("capability_result"), "call_id" => JSON::Any.new(call_id)} of String => JSON::Any
        payload["ok"] = JSON::Any.new(ok)
        if ok
          payload["result"] = result || JSON::Any.new(nil)
        else
          payload["error"] = JSON::Any.new({
            "code"    => JSON::Any.new(error_code || "capability_failed"),
            "message" => JSON::Any.new(error_message || ""),
          })
        end
        frame = payload.to_json
        if frame.bytesize > MAX_FRAME
          raise ProtocolError.new("capability_result frame exceeds #{MAX_FRAME} bytes")
        end
        frame
      end

      private def self.require_fields(obj : Hash(String, JSON::Any), names : Tuple, kind : String) : Nil
        names.each do |name|
          unless obj.has_key?(name)
            raise ProtocolError.new("#{kind} frame missing '#{name}'")
          end
        end
      end

      private def self.reject_unknown(obj : Hash(String, JSON::Any), allowed : Tuple, kind : String) : Nil
        obj.each_key do |key|
          unless allowed.includes?(key)
            raise ProtocolError.new("#{kind} frame has unknown field '#{key}' (closed set)")
          end
        end
      end

      private def self.string_array(value : JSON::Any?, field : String) : Array(String)
        raise ProtocolError.new("registered.#{field} must be an array") unless value
        arr = value.as_a?
        raise ProtocolError.new("registered.#{field} must be an array of strings") unless arr
        arr.map do |item|
          text = item.as_s?
          raise ProtocolError.new("registered.#{field} entries must be strings") unless text
          text
        end
      end
    end
  end
end
