require "./protocol"

# 注入脚本的 DSL prelude（M3-WP4，#16；design.md §12.2）。
#
# 宿主 runner 每次调用合成一个程序文件：STATIC_PRELUDE（DSL 定义）+
# REQUEST_BOOTSTRAP（stdin 读 request 并注入变量）+ plugin.rb +
# DISPATCH_EPILOGUE。合成脚本只允许 mruby 核心 API（无 String#ord /
# Integer#chr 等扩展 gem）；JSON 来自 mruby-sebas-json，sebas_print/
# sebas_read 来自 mruby-sebas-stdio。
#
# 帧协议（stdout）：registered → 0..n × capability_call → 恰好一个 result，
# 其后无输出。handler 以 $payload 为唯一业务参数；$action/$config/$context/
# $idempotency_key 经注入变量提供（§12.2 / §12.11 统一执行规则）。
#
# heredoc 口径（ameba Style/HeredocEscape/Indent）：body 相对 closing 标记
# 缩进 2 格；STATIC_PRELUDE 用引号标记（保留 `"\n"` 字面转义给 Ruby），
# 其余无转义内容用非引号标记。
module Sebas
  module Plugins
    module Prelude
      # DSL 定义段：on_action/on_hook/capability + 结构化错误类型。
      STATIC_PRELUDE = <<-'RUBY'
        # == SEBAS PLUGIN PRELUDE (host-injected; do not edit) ==
        # 沙箱插件 DSL（design.md §12.2）：声明式注册 + capability 同步 host-call。
        $sebas_actions = {}
        $sebas_hooks = {}
        $sebas_call_seq = 0

        class SebasPluginError < RuntimeError
          attr_reader :sebas_code

          def initialize(code, message)
            @sebas_code = code.to_s
            super(message.to_s)
          end
        end

        def sebas_emit_frame(obj)
          sebas_print(JSON.generate(obj))
          sebas_print("\n")
          nil
        end

        def sebas_register(table, name, blk)
          unless name.is_a?(String) && !name.empty?
            raise SebasPluginError.new("invalid_registration", "handler name must be a non-empty string")
          end
          if $sebas_actions[name] || $sebas_hooks[name]
            raise SebasPluginError.new("duplicate_registration", "handler already registered: " + name)
          end
          table[name] = blk
          nil
        end

        def on_action(name, &blk)
          sebas_register($sebas_actions, name, blk)
        end

        def on_hook(name, &blk)
          sebas_register($sebas_hooks, name, blk)
        end

        # gate/transform 的 deny 短路（M3-WP5，#17；§12.11 示例 DSL）：
        # 抛结构化错误（code=hook_deny，message 为 "deny_code: reason"），
        # 宿主按 deny 裁决处理——gate 停链，transform fail-closed。
        def deny!(code, reason)
          raise SebasPluginError.new("hook_deny", code.to_s + ": " + reason.to_s)
        end

        # transform 的修改语法糖（§12.11 示例 DSL）：返回替换后的完整
        # payload——宿主按裸返回值语义重过 payload schema 校验。
        def modify!(value)
          value
        end

        def capability(name, params)
          $sebas_call_seq += 1
          call_id = $sebas_call_seq.to_s
          sebas_emit_frame({"type" => "capability_call", "call_id" => call_id,
                            "capability" => name, "params" => params})
          line = sebas_read
          unless line
            raise SebasPluginError.new("capability_channel_closed",
              "no reply for capability call " + call_id)
          end
          reply = JSON.parse(line)
          rtype = reply["type"]
          unless rtype == "capability_result"
            raise SebasPluginError.new("capability_reply_invalid",
              "expected capability_result, got " + rtype.to_s)
          end
          unless reply["call_id"] == call_id
            raise SebasPluginError.new("capability_reply_mismatch",
              "capability reply call_id mismatch (expected " + call_id + ")")
          end
          if reply["ok"] == true
            reply["result"]
          else
            err = reply["error"] || {}
            raise SebasPluginError.new(err["code"] || "capability_failed",
              err["message"] || "capability call failed")
          end
        end
        RUBY

      # 请求引导段：stdin 读单行 request（§12.2「stdin 输入请求」），注入
      # §12.2 变量。协议版本不符 → 结构化错误帧（不执行任何插件代码）。
      REQUEST_BOOTSTRAP = <<-RUBY # ameba:disable Style/MultilineStringLiteral
        # == SEBAS REQUEST BOOTSTRAP (host-injected) ==
        $sebas_request_line = sebas_read
        $sebas_request_id = ""
        begin
          if $sebas_request_line.nil?
            sebas_emit_frame({"type" => "result", "request_id" => "",
                              "ok" => false,
                              "error" => {"code" => "no_request",
                                          "message" => "no request on stdin"}})
            exit 0
          end
          request = JSON.parse($sebas_request_line)
          unless request["protocol_version"] == 1
            sebas_emit_frame({"type" => "result", "request_id" => request["request_id"].to_s,
                              "ok" => false,
                              "error" => {"code" => "unsupported_protocol",
                                          "message" => "protocol_version must be 1"}})
            exit 0
          end
        rescue => e
          sebas_emit_frame({"type" => "result", "request_id" => "",
                            "ok" => false,
                            "error" => {"code" => "invalid_request",
                                        "message" => e.message.to_s}})
          exit 0
        end
        $sebas_request_id = request["request_id"].to_s
        $action = request["action"]
        $context = request["context"] || {}
        $payload = request["payload"] || {}
        $config = request["config"] || {}
        $idempotency_key = request["idempotency_key"]
        RUBY

      # 派发尾段：注册集报告 → 精确派发 → 恰好一个 result 帧。
      # 未注册 → 结构化 handler_not_registered（非崩溃）；重复/无效注册在
      # 注册时即抛（经装载包装转结构化 duplicate_registration）。
      DISPATCH_EPILOGUE = <<-RUBY # ameba:disable Style/MultilineStringLiteral
        # == SEBAS DISPATCH (host-injected) ==
        sebas_emit_frame({"type" => "registered",
                          "actions" => $sebas_actions.keys,
                          "hooks" => $sebas_hooks.keys})
        handler = $sebas_actions[$action] || $sebas_hooks[$action]
        if handler.nil?
          sebas_emit_frame({"type" => "result", "request_id" => $sebas_request_id,
                            "ok" => false,
                            "error" => {"code" => "handler_not_registered",
                                        "message" => "no handler registered for " + $action.to_s}})
        else
          begin
            value = handler.call($payload)
            json_like = value.is_a?(Hash) || value.is_a?(Array) || value.is_a?(String) ||
                        value.is_a?(Integer) || value.is_a?(Float) ||
                        value == true || value == false || value.nil?
            if json_like
              sebas_emit_frame({"type" => "result", "request_id" => $sebas_request_id,
                                "ok" => true, "value" => value})
            else
              sebas_emit_frame({"type" => "result", "request_id" => $sebas_request_id,
                                "ok" => false,
                                "error" => {"code" => "invalid_result",
                                            "message" => "handler must return a JSON-like value"}})
            end
          rescue SebasPluginError => e
            sebas_emit_frame({"type" => "result", "request_id" => $sebas_request_id,
                              "ok" => false,
                              "error" => {"code" => e.sebas_code, "message" => e.message.to_s}})
          rescue => e
            sebas_emit_frame({"type" => "result", "request_id" => $sebas_request_id,
                              "ok" => false,
                              "error" => {"code" => "plugin_exception",
                                          "message" => e.message.to_s}})
          end
        end
        exit 0
        RUBY

      # 插件源码装载段：begin/rescue 包装——装载期异常（重复注册、顶层抛错）
      # 转结构化错误帧退出，不裸崩进程（验收：重复注册拒绝为结构化结果）。
      PLUGIN_WRAPPER = <<-RUBY # ameba:disable Style/MultilineStringLiteral
        # == SEBAS PLUGIN LOAD (host-injected) ==
        begin
        RUBY

      private def self.plugin_wrapper_tail : String
        <<-RUBY # ameba:disable Style/MultilineStringLiteral
          rescue SebasPluginError => e
            sebas_emit_frame({"type" => "result", "request_id" => $sebas_request_id,
                              "ok" => false,
                              "error" => {"code" => e.sebas_code, "message" => e.message.to_s}})
            exit 0
          rescue => e
            sebas_emit_frame({"type" => "result", "request_id" => $sebas_request_id,
                              "ok" => false,
                              "error" => {"code" => "plugin_exception",
                                          "message" => "load failed: " + e.message.to_s}})
            exit 0
          end
          RUBY
      end

      # 合成程序：静态 DSL + 请求引导 + 插件源码（装载包装）+ 派发尾段。
      def self.compose(plugin_source : String) : String
        String.build do |io|
          io << STATIC_PRELUDE << "\n" << REQUEST_BOOTSTRAP
          io << "\n" << PLUGIN_WRAPPER
          io << "# == plugin source (begin) ==\n"
          io << plugin_source
          io << "\n# == plugin source (end) ==\n"
          io << plugin_wrapper_tail
          io << "\n" << DISPATCH_EPILOGUE
        end
      end
    end
  end
end
