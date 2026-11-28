require "json"

# 钩子目录与 payload 契约（M3-WP5，#17；design.md §12.11 首版闭集 22 个）。
#
# 本文件是 §12.11「宿主注入点与契约」的机读权威：
# - kind：observe / gate / transform / gate_transform（gate+transform 同步链，
#   每个处理器接收上一个已校验结果；observe 按注册快照执行、忽略返回值）；
# - fields：该 hook payload 的键与类型闭集——「表中列出字段的行，其字段即
#   该 hook payload 的必需键；宿主不得臆加未列字段」（§12.11 统一执行规则）。
#   §12.11 未列明字段的 hook 在本文件定稿（WP5 授权范围）；
# - sensitive：payload 含消息/参数/文本等敏感内容，订阅它要求 manifest
#   capabilities 显式声明 hooks.sensitive（§12.11「按 manifest capability
#   单独批准，默认最小字段与脱敏」）。
#
# 值类型限于 §12.2 JSON-like 原语：string/int/bool/enum/null/数组/哈希；
# 嵌套深度与总大小受 NDJSON 上限约束（校验见 Schema）。
module Sebas
  module Plugins
    module Hooks
      # 订阅敏感 hook 所需的 manifest capability 名称（§12.11 单独批准）。
      SENSITIVE_CAPABILITY = "hooks.sensitive"

      enum Kind
        Observe
        Gate
        Transform
        GateTransform
      end

      # 字段类型闭集：enum 用允许值数组表达；NULL 表示可空联合（T|null）。
      enum FieldType
        Str
        Int
        Bool
        StrArray
        Hash
        Null
      end

      # nullable=true：键必须在、值可为 null（§12.11 的 T|null 口径）；
      # optional=true：键可省略。subfields 非空时为结构化对象（键集闭），
      # 例如 task.end.error 至少含 code:string。
      record Field,
        type : FieldType,
        values : Array(String)? = nil,
        optional : Bool = false,
        nullable : Bool = false,
        subfields : Hash(String, Field)? = nil

      record Def,
        name : String,
        kind : Kind,
        fields : Hash(String, Field),
        sensitive : Bool

      # 22 个首版钩子（gateway.start/stop 是两个独立名称，验收分别覆盖）。
      # 字段类型标注：
      #   S=Str, I=Int, B=Bool, SA=StrArray, H=Hash, N=Null（可空）
      # 值为可空时 optional 仅表示「键必须存在、值可为 null」或「键可省略」，
      # 由 Field#optional 区分（true=键可省略）。
      DEFINITIONS = {
        "message.received" => Def.new("message.received", Kind::Observe, {
          "channel"    => Field.new(FieldType::Str),
          "account_id" => Field.new(FieldType::Str),
          "peer"       => Field.new(FieldType::Str),
          "message_id" => Field.new(FieldType::Str, optional: true),
          "size"       => Field.new(FieldType::Int),
        }, false),
        "message.sending" => Def.new("message.sending", Kind::GateTransform, {
          "channel"     => Field.new(FieldType::Str),
          "account_id"  => Field.new(FieldType::Str),
          "peer"        => Field.new(FieldType::Str),
          "content"     => Field.new(FieldType::Str),
          "attachments" => Field.new(FieldType::StrArray),
        }, true),
        "message.sent" => Def.new("message.sent", Kind::Observe, {
          "status"     => Field.new(FieldType::Str, values: %w[success error]),
          "message_id" => Field.new(FieldType::Str, nullable: true),
          "error_code" => Field.new(FieldType::Str, nullable: true),
        }, false),
        "agent.turn.before" => Def.new("agent.turn.before", Kind::Gate, {
          "agent_id"    => Field.new(FieldType::Str),
          "session_key" => Field.new(FieldType::Str),
        }, false),
        "agent.turn.after" => Def.new("agent.turn.after", Kind::Observe, {
          "agent_id"    => Field.new(FieldType::Str),
          "status"      => Field.new(FieldType::Str, values: %w[success error interrupted]),
          "duration_ms" => Field.new(FieldType::Int),
        }, false),
        "llm.request.before" => Def.new("llm.request.before", Kind::GateTransform, {
          "provider"      => Field.new(FieldType::Str),
          "model"         => Field.new(FieldType::Str),
          "message_count" => Field.new(FieldType::Int),
          "system_append" => Field.new(FieldType::Str),
        }, true),
        "llm.request.after" => Def.new("llm.request.after", Kind::Observe, {
          "provider"    => Field.new(FieldType::Str),
          "model"       => Field.new(FieldType::Str),
          "duration_ms" => Field.new(FieldType::Int),
          "usage"       => Field.new(FieldType::Hash),
        }, false),
        "llm.request.error" => Def.new("llm.request.error", Kind::Observe, {
          "provider"    => Field.new(FieldType::Str),
          "attempt"     => Field.new(FieldType::Int),
          "status_code" => Field.new(FieldType::Int, nullable: true),
          "error_code"  => Field.new(FieldType::Str),
        }, false),
        "llm.response.transform" => Def.new("llm.response.transform", Kind::Transform, {
          "provider" => Field.new(FieldType::Str),
          "model"    => Field.new(FieldType::Str),
          "text"     => Field.new(FieldType::Str),
        }, true),
        "tool.call.before" => Def.new("tool.call.before", Kind::GateTransform, {
          "tool_id"     => Field.new(FieldType::Str),
          "request_id"  => Field.new(FieldType::Str),
          "session_key" => Field.new(FieldType::Str),
          "params"      => Field.new(FieldType::Hash),
        }, true),
        "tool.call.after" => Def.new("tool.call.after", Kind::Observe, {
          "tool_id"        => Field.new(FieldType::Str),
          "request_id"     => Field.new(FieldType::Str),
          "session_key"    => Field.new(FieldType::Str),
          "status"         => Field.new(FieldType::Str, values: %w[success error exception]),
          "duration_ms"    => Field.new(FieldType::Int),
          "result_summary" => Field.new(FieldType::Str),
        }, false),
        "tool.result.transform" => Def.new("tool.result.transform", Kind::Transform, {
          "tool_id"    => Field.new(FieldType::Str),
          "request_id" => Field.new(FieldType::Str),
          "text"       => Field.new(FieldType::Str),
        }, true),
        "session.start" => Def.new("session.start", Kind::Observe, {
          "session_key" => Field.new(FieldType::Str),
        }, false),
        "session.end" => Def.new("session.end", Kind::Observe, {
          "session_key" => Field.new(FieldType::Str),
          "reason"      => Field.new(FieldType::Str),
        }, false),
        "session.compact.before" => Def.new("session.compact.before", Kind::Observe, {
          "session_key" => Field.new(FieldType::Str),
        }, false),
        "session.compact.after" => Def.new("session.compact.after", Kind::Observe, {
          "session_key"    => Field.new(FieldType::Str),
          "summary_tokens" => Field.new(FieldType::Int),
          "summary"        => Field.new(FieldType::Str),
        }, true), # summary 是会话转写摘要文本——sensitive（M3-WP5 review CWE-862）
        "memory.remember.before" => Def.new("memory.remember.before", Kind::GateTransform, {
          "entry" => Field.new(FieldType::Hash),
        }, true),
        "memory.remember.after" => Def.new("memory.remember.after", Kind::Observe, {
          "memory_id" => Field.new(FieldType::Str),
          "kind"      => Field.new(FieldType::Str),
          "tags"      => Field.new(FieldType::StrArray),
        }, false),
        "task.start" => Def.new("task.start", Kind::Observe, {
          "run_id"      => Field.new(FieldType::Str),
          "workflow_id" => Field.new(FieldType::Str),
        }, false),
        "task.end" => Def.new("task.end", Kind::Observe, {
          "task_id" => Field.new(FieldType::Str),
          "status"  => Field.new(FieldType::Str),
          "error"   => Field.new(FieldType::Hash, optional: true, nullable: true, subfields: {
            "code"    => Field.new(FieldType::Str),
            "message" => Field.new(FieldType::Str, optional: true),
          }), # §12.11：error 为 object|null——nullable 允许显式 null
        }, false),
        "gateway.start" => Def.new("gateway.start", Kind::Observe, {} of String => Field, false),
        "gateway.stop"  => Def.new("gateway.stop", Kind::Observe, {} of String => Field, false),
      }

      Log = Sebas::Log.for("plugins.hooks")

      class SchemaError < RuntimeError; end

      # 名称闭集：未列出的专属能力不自动成为 Sebas 契约（§12.11）。
      def self.definition?(name : String) : Def?
        DEFINITIONS[name]?
      end

      def self.definition!(name : String) : Def
        definition?(name) || raise SchemaError.new("unknown hook '#{name}'")
      end

      def self.names : Array(String)
        DEFINITIONS.keys.sort!
      end

      # payload 按 schema 校验：键集闭（多余键拒绝）、列出的必需键必须在、
      # optional 字段可省略但出现时类型须符；task.end.error 为结构化错误
      # 对象（出现时至少含 code: string，可含 message: string）。
      # 值类型按 §12.2 JSON-like 递归：哈希键为 string、值为原语，嵌套深度
      # 与大小受 NDJSON 帧上限约束（此处按帧上限折算大小上限）。
      def self.validate_payload!(name : String, payload : JSON::Any) : Nil
        defn = definition!(name)
        obj = payload.as_h?
        raise SchemaError.new("hook #{name} payload must be a JSON object") unless obj

        obj.each_key do |key|
          unless defn.fields[key]?
            raise SchemaError.new("hook #{name} payload has undeclared key '#{key}'")
          end
        end
        defn.fields.each do |key, field|
          value = obj[key]?
          if value.nil?
            raise SchemaError.new("hook #{name} payload missing key '#{key}'") unless field.optional
            next
          end
          if value.raw.nil?
            unless field.nullable
              raise SchemaError.new("hook #{name} payload '#{key}' must not be null")
            end
            next
          end
          validate_value!(name, key, value, field)
        end
      end

      # ameba:disable Metrics/CyclomaticComplexity — 类型分派校验，分支即语义
      private def self.validate_value!(hook : String, key : String, value : JSON::Any,
                                       field : Field, depth : Int32 = 0) : Nil
        if depth > MAX_DEPTH
          raise SchemaError.new("hook #{hook} payload '#{key}' exceeds nesting depth #{MAX_DEPTH}")
        end
        case field.type
        when .str?
          unless value.as_s?
            raise SchemaError.new("hook #{hook} payload '#{key}' must be a string (got #{value.raw.class})")
          end
        when .int?
          unless value.as_i64? || value.as_i?
            raise SchemaError.new("hook #{hook} payload '#{key}' must be an integer")
          end
        when .bool?
          # as_bool? 对 false 返回 false——truthiness 判断会把合法的 false
          # 误判为非法值；类型判定必须用 raw is_a?
          unless value.raw.is_a?(Bool)
            raise SchemaError.new("hook #{hook} payload '#{key}' must be a boolean")
          end
        when .str_array?
          arr = value.as_a?
          raise SchemaError.new("hook #{hook} payload '#{key}' must be a string array") unless arr
          arr.each do |item|
            unless item.as_s?
              raise SchemaError.new("hook #{hook} payload '#{key}' array items must be strings")
            end
          end
        when .hash?
          sub = value.as_h?
          raise SchemaError.new("hook #{hook} payload '#{key}' must be an object") unless sub
          if subfields = field.subfields
            validate_structured!(hook, key, sub, subfields, depth + 1)
          else
            validate_hash_value!(hook, key, sub, depth + 1)
          end
        when .null?
          # 可空联合：null 已由调用方处理，此处只为显式声明保留
        end
        if values = field.values
          actual = value.as_s?
          unless actual && values.includes?(actual)
            raise SchemaError.new("hook #{hook} payload '#{key}' must be one of #{values.join("|")} (got #{actual.inspect})")
          end
        end
      end

      # 结构化对象：键集闭（未声明键拒绝）、必填子字段在、子字段值递归校验
      # （§12.11 task.end.error：至少含 code:string，可含 message:string）。
      private def self.validate_structured!(hook : String, key : String,
                                            obj : Hash(String, JSON::Any),
                                            subfields : Hash(String, Field), depth : Int32) : Nil
        obj.each_key do |sub_key|
          unless subfields[sub_key]?
            raise SchemaError.new("hook #{hook} payload '#{key}' has undeclared key '#{sub_key}'")
          end
        end
        subfields.each do |sub_key, sub_field|
          value = obj[sub_key]?
          if value.nil?
            raise SchemaError.new("hook #{hook} payload '#{key}.#{sub_key}' is required") unless sub_field.optional
            next
          end
          validate_value!(hook, "#{key}.#{sub_key}", value, sub_field, depth)
        end
      end

      private def self.validate_hash_value!(hook : String, key : String, obj : JSON::Any::Type,
                                            depth : Int32) : Nil
        obj.each do |k, v|
          raise SchemaError.new("hook #{hook} payload '#{key}' object keys must be strings") unless k.is_a?(String)
          validate_json_like!(hook, key, v, depth)
        end
      end

      # JSON-like 递归（§12.2）：哈希值为 string/int/float/bool/null/数组/哈希。
      private def self.validate_json_like!(hook : String, key : String, value : JSON::Any,
                                           depth : Int32) : Nil
        raise SchemaError.new("hook #{hook} payload '#{key}' nesting exceeds depth") if depth > MAX_DEPTH
        ok = value.as_s? || value.as_i64? || value.as_i? || value.as_f? ||
             value.raw.is_a?(Bool) || value.raw.nil?
        return if ok
        if arr = value.as_a?
          arr.each { |item| validate_json_like!(hook, key, item, depth + 1) }
          return
        end
        if sub = value.as_h?
          sub.each do |k, v|
            raise SchemaError.new("hook #{hook} payload '#{key}' object keys must be strings") unless k.is_a?(String)
            validate_json_like!(hook, key, v, depth + 1)
          end
          return
        end
        raise SchemaError.new("hook #{hook} payload '#{key}' contains a non JSON-like value")
      end

      private MAX_DEPTH = 8
    end
  end
end
