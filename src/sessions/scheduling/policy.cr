require "yaml"
require "./policy_overlays"
require "json"

# 会话输入调度策略（session-input-scheduling.md §3；M3-WP1 承载）
#
# 配置层级（契约 §3.1，两个作用域互不跨域）：
#   agent 会话：内置默认值 → gateway.session → agents.<name>.session
#   workflow  ：内置默认（逐事件 queue）→ workflow.batch（不继承 gateway.session / agents.*.session）
# 嵌套对象按字段递归合并（nil = 继承上一层），标量/布尔/枚举整体覆盖；
# 解析结果为不可变 PolicySnapshot，每次 admission 解析一次并保存。
module Sebas
  module Sessions
    module Scheduling
      class PolicyError < ::Exception; end

      # ---- 可调参数硬范围（契约 §3.3 参数表）----
      RANGES = {
        "debounce.idle_ms"            => 0..10000,
        "debounce.max_wait_ms"        => 1..60000,
        "debounce.max_messages"       => 1..200,
        "debounce.max_bytes"          => 256..1048576,
        "debounce.max_active_buckets" => 1..256,
        "steer.debounce_ms"           => 0..5000,
        "steer.max_pending_messages"  => 1..100,
        "steer.max_wait_ms"           => 1..300000,
      }

      DEFAULT_IDLE_MS             =  1000_i64
      DEFAULT_MAX_WAIT_MS         =  5000_i64
      DEFAULT_MAX_MESSAGES        =    20_i64
      DEFAULT_MAX_BYTES           = 32768_i64
      DEFAULT_FLUSH_ON_TURN_END   = true
      DEFAULT_MAX_ACTIVE_BUCKETS  =     32_i64
      DEFAULT_MAX_PENDING_BATCHES =     32_i64
      DEFAULT_MAX_PENDING_BYTES   = 262144_i64
      DEFAULT_STEER_DEBOUNCE_MS   =    300_i64
      DEFAULT_STEER_MAX_PENDING   =     16_i64
      DEFAULT_STEER_MAX_WAIT_MS   =  30000_i64

      # ---- YAML 配置节点（schema.cr 复用；nil = 未提供，继承上一层）----
      #
      # raise_on_unknown_fields：未知键直接拒绝加载，不静默回退（契约 §3.4）。
      class SessionPolicyConfig
        include YAML::Serializable
        include YAML::Serializable::Strict
        getter batch_mode : String?
        getter debounce : DebouncePolicy?
        getter queue : QueuePolicy?
        getter steer : SteerPolicy?

        def initialize(@batch_mode = nil, @debounce = nil, @queue = nil, @steer = nil)
        end

        # workflow DSL 的 YAML::Any 节点解析（未知键/类型错误即抛 PolicyError）
        def self.from_any(node : YAML::Any) : SessionPolicyConfig
          h = node.as_h?
          raise PolicyError.new("must be a mapping") unless h
          batch_mode = nil
          debounce = nil
          queue = nil
          steer = nil
          h.each do |k, v|
            key = k.as_s?
            raise PolicyError.new("unknown key '#{k.inspect}'") unless key
            case key
            when "batch_mode"
              batch_mode = v.as_s?
              raise PolicyError.new("batch_mode must be a string") unless batch_mode
            when "debounce" then debounce = DebouncePolicy.from_any(v)
            when "queue"    then queue = QueuePolicy.from_any(v)
            when "steer"    then steer = SteerPolicy.from_any(v)
            else                 raise PolicyError.new("unknown key '#{key}'")
            end
          end
          new(batch_mode, debounce, queue, steer)
        end
      end

      class DebouncePolicy
        include YAML::Serializable
        include YAML::Serializable::Strict
        getter idle_ms : Int64?
        getter max_wait_ms : Int64?
        getter max_messages : Int64?
        getter max_bytes : Int64?
        getter flush_on_turn_end : Bool?
        getter group_by : String?
        getter max_active_buckets : Int64?

        def initialize(@idle_ms = nil, @max_wait_ms = nil, @max_messages = nil,
                       @max_bytes = nil, @flush_on_turn_end = nil,
                       @group_by = nil, @max_active_buckets = nil)
        end

        INT_FIELDS = %w[idle_ms max_wait_ms max_messages max_bytes max_active_buckets]

        def self.from_any(node : YAML::Any) : DebouncePolicy
          h = node.as_h?
          raise PolicyError.new("debounce must be a mapping") unless h
          fields = {} of String => YAML::Any
          h.each do |k, v|
            key = k.as_s?
            raise PolicyError.new("unknown key '#{k.inspect}'") unless key
            if INT_FIELDS.includes?(key)
              fields[key] = v
            elsif key == "flush_on_turn_end"
              raise PolicyError.new("debounce.flush_on_turn_end must be a boolean") unless v.raw.is_a?(Bool)
              fields[key] = v
            elsif key == "group_by"
              raise PolicyError.new("debounce.group_by must be a string") unless v.as_s?
              fields[key] = v
            else
              raise PolicyError.new("unknown key '#{key}'")
            end
          end
          new(
            int_field("debounce.idle_ms", fields),
            int_field("debounce.max_wait_ms", fields),
            int_field("debounce.max_messages", fields),
            int_field("debounce.max_bytes", fields),
            fields["flush_on_turn_end"]?.try(&.as_bool?),
            fields["group_by"]?.try(&.as_s?),
            int_field("debounce.max_active_buckets", fields),
          )
        end

        private def self.int_field(label : String, fields : Hash(String, YAML::Any)) : Int64?
          raw = fields[label.lchop("debounce.")]?
          return unless raw
          iv = raw.as_i?
          raise PolicyError.new("#{label} must be an integer") unless iv
          iv.to_i64
        end
      end

      class QueuePolicy
        include YAML::Serializable
        include YAML::Serializable::Strict
        getter max_pending_batches : Int64?
        getter max_pending_bytes : Int64?

        def initialize(@max_pending_batches = nil, @max_pending_bytes = nil)
        end

        def self.from_any(node : YAML::Any) : QueuePolicy
          h = node.as_h?
          raise PolicyError.new("queue must be a mapping") unless h
          max_pending_batches = nil
          max_pending_bytes = nil
          h.each do |k, v|
            key = k.as_s?
            raise PolicyError.new("unknown key '#{k.inspect}'") unless key
            case key
            when "max_pending_batches"
              max_pending_batches = v.as_i?.try(&.to_i64)
              raise PolicyError.new("queue.#{key} must be an integer") unless max_pending_batches
            when "max_pending_bytes"
              max_pending_bytes = v.as_i?.try(&.to_i64)
              raise PolicyError.new("queue.#{key} must be an integer") unless max_pending_bytes
            else raise PolicyError.new("unknown key '#{key}'")
            end
          end
          new(max_pending_batches, max_pending_bytes)
        end
      end

      class SteerPolicy
        include YAML::Serializable
        include YAML::Serializable::Strict
        getter enabled : Bool?
        getter debounce_ms : Int64?
        getter max_pending_messages : Int64?
        getter max_wait_ms : Int64?

        def initialize(@enabled = nil, @debounce_ms = nil,
                       @max_pending_messages = nil, @max_wait_ms = nil)
        end

        def self.from_any(node : YAML::Any) : SteerPolicy
          h = node.as_h?
          raise PolicyError.new("steer must be a mapping") unless h
          enabled = nil
          debounce_ms = nil
          max_pending_messages = nil
          max_wait_ms = nil
          h.each do |k, v|
            key = k.as_s?
            raise PolicyError.new("unknown key '#{k.inspect}'") unless key
            case key
            when "enabled"
              raise PolicyError.new("steer.#{key} must be a boolean") unless v.raw.is_a?(Bool)
              enabled = v.as_bool?
            when "debounce_ms"
              debounce_ms = v.as_i?.try(&.to_i64)
              raise PolicyError.new("steer.#{key} must be an integer") unless debounce_ms
            when "max_pending_messages"
              max_pending_messages = v.as_i?.try(&.to_i64)
              raise PolicyError.new("steer.#{key} must be an integer") unless max_pending_messages
            when "max_wait_ms"
              max_wait_ms = v.as_i?.try(&.to_i64)
              raise PolicyError.new("steer.#{key} must be an integer") unless max_wait_ms
            else raise PolicyError.new("unknown key '#{key}'")
            end
          end
          new(enabled, debounce_ms, max_pending_messages, max_wait_ms)
        end
      end

      # ---- 解析后的不可变策略快照（admission 时保存，在途批次永久沿用）----
      struct PolicySnapshot
        include JSON::Serializable
        getter batch_mode : String # "queue" | "debounce"
        getter idle_ms : Int64     # 0 = 不等静默（idle 条件禁用）
        getter max_wait_ms : Int64 # 不被新消息重置
        getter max_messages : Int64
        getter max_bytes : Int64
        @flush_on_turn_end : Bool

        def flush_on_turn_end? : Bool
          @flush_on_turn_end
        end

        getter group_by : String # "sender" | "session"
        getter max_active_buckets : Int64
        getter max_pending_batches : Int64
        getter max_pending_bytes : Int64
        @steer_enabled : Bool

        def steer_enabled? : Bool
          @steer_enabled
        end

        getter steer_debounce_ms : Int64
        getter steer_max_pending_messages : Int64
        getter steer_max_wait_ms : Int64

        def initialize(@batch_mode, @idle_ms, @max_wait_ms, @max_messages, @max_bytes,
                       @flush_on_turn_end, @group_by, @max_active_buckets,
                       @max_pending_batches, @max_pending_bytes,
                       @steer_enabled, @steer_debounce_ms, @steer_max_pending_messages,
                       @steer_max_wait_ms)
        end
      end

      module Policy
        extend self

        # 内置安全默认值（契约 §3.3 默认列）
        def builtin : PolicySnapshot
          snapshot_from_fields(builtin_fields)
        end

        # agent 会话作用域：内置 → gateway.session → agents.<name>.session（递归字段级合并）
        def resolve_session(gateway : SessionPolicyConfig?, agent : SessionPolicyConfig?) : PolicySnapshot
          snapshot_from_fields(resolve_chain(builtin_fields, [gateway, agent]))
        end

        # workflow 作用域：内置（逐事件 queue）→ workflow.batch；不继承 gateway.session / agents.*.session
        # （契约 §3.1：确定性 workflow 默认一事件一 run，只有显式声明 batch 才聚合）
        def resolve_workflow(batch : SessionPolicyConfig?) : PolicySnapshot
          snapshot_from_fields(resolve_chain(builtin_fields, [batch]))
        end

        # 配置树校验入口（loader.validate 调用；返回带作用域前缀的错误行，不 raise）
        def validate_config_errors(gateway : SessionPolicyConfig?,
                                   agents : Hash(String, SessionPolicyConfig?)) : Array(String)
          errors = [] of String
          errors.concat(scoped("gateway.session", gateway, nil)) if gateway
          agents.each do |name, agent_cfg|
            next unless agent_cfg
            errors.concat(scoped("agents.#{name}.session", gateway, agent_cfg))
          end
          errors
        end

        # 解析合并后的快照；PolicyError 的错误行加作用域前缀后返回
        private def scoped(scope : String, gateway : SessionPolicyConfig?, agent : SessionPolicyConfig?) : Array(String)
          resolve_session(gateway, agent)
          [] of String
        rescue ex : PolicyError
          ex.message.to_s.lines
            .select(&.strip.starts_with?("- "))
            .map { |line| "#{scope}.#{line.strip.lchop("- ").strip}" }
        end

        # ---- 字段链合并（内部表示；nil = 继承上一层）----

        private record ChainFields, batch_mode : String?, idle_ms : Int64?, max_wait_ms : Int64?,
          max_messages : Int64?, max_bytes : Int64?, flush_on_turn_end : Bool?, group_by : String?,
          max_active_buckets : Int64?, max_pending_batches : Int64?, max_pending_bytes : Int64?,
          steer_enabled : Bool?, steer_debounce_ms : Int64?, steer_max_pending_messages : Int64?,
          steer_max_wait_ms : Int64?

        private def resolve_chain(base : ChainFields, configs : Array(SessionPolicyConfig?)) : ChainFields
          f = base
          configs.compact.each do |cfg|
            d = cfg.debounce
            q = cfg.queue
            s = cfg.steer
            f = ChainFields.new(
              pick(f.batch_mode, cfg.batch_mode),
              pick(f.idle_ms, d.try(&.idle_ms)),
              pick(f.max_wait_ms, d.try(&.max_wait_ms)),
              pick(f.max_messages, d.try(&.max_messages)),
              pick(f.max_bytes, d.try(&.max_bytes)),
              pick(f.flush_on_turn_end, d.try(&.flush_on_turn_end)),
              pick(f.group_by, d.try(&.group_by)),
              pick(f.max_active_buckets, d.try(&.max_active_buckets)),
              pick(f.max_pending_batches, q.try(&.max_pending_batches)),
              pick(f.max_pending_bytes, q.try(&.max_pending_bytes)),
              pick(f.steer_enabled, s.try(&.enabled)),
              pick(f.steer_debounce_ms, s.try(&.debounce_ms)),
              pick(f.steer_max_pending_messages, s.try(&.max_pending_messages)),
              pick(f.steer_max_wait_ms, s.try(&.max_wait_ms)),
            )
          end
          f
        end

        # nil = 继承上一层；显式提供的值（含 0 / false）整体覆盖
        private def pick(inherited, override)
          override.nil? ? inherited : override
        end

        private def builtin_fields : ChainFields
          ChainFields.new("queue", DEFAULT_IDLE_MS, DEFAULT_MAX_WAIT_MS, DEFAULT_MAX_MESSAGES,
            DEFAULT_MAX_BYTES, DEFAULT_FLUSH_ON_TURN_END, "sender", DEFAULT_MAX_ACTIVE_BUCKETS,
            DEFAULT_MAX_PENDING_BATCHES, DEFAULT_MAX_PENDING_BYTES, false, DEFAULT_STEER_DEBOUNCE_MS,
            DEFAULT_STEER_MAX_PENDING, DEFAULT_STEER_MAX_WAIT_MS)
        end

        private def snapshot_from_fields(f : ChainFields) : PolicySnapshot
          snapshot = PolicySnapshot.new(
            pick("queue", f.batch_mode),
            pick(DEFAULT_IDLE_MS, f.idle_ms),
            pick(DEFAULT_MAX_WAIT_MS, f.max_wait_ms),
            pick(DEFAULT_MAX_MESSAGES, f.max_messages),
            pick(DEFAULT_MAX_BYTES, f.max_bytes),
            pick(DEFAULT_FLUSH_ON_TURN_END, f.flush_on_turn_end),
            pick("sender", f.group_by),
            pick(DEFAULT_MAX_ACTIVE_BUCKETS, f.max_active_buckets),
            pick(DEFAULT_MAX_PENDING_BATCHES, f.max_pending_batches),
            pick(DEFAULT_MAX_PENDING_BYTES, f.max_pending_bytes),
            pick(false, f.steer_enabled),
            pick(DEFAULT_STEER_DEBOUNCE_MS, f.steer_debounce_ms),
            pick(DEFAULT_STEER_MAX_PENDING, f.steer_max_pending_messages),
            pick(DEFAULT_STEER_MAX_WAIT_MS, f.steer_max_wait_ms),
          )
          errs = validate_snapshot_errors(snapshot)
          raise PolicyError.new("scheduling policy validation failed:\n" +
                                errs.map { |e| "  - #{e}" }.join("\n")) unless errs.empty?
          snapshot
        end

        # ---- 硬范围校验（契约 §3.3/§3.4）----
        #
        # 非法枚举拒绝；显式提供的字段即使功能关闭也必须通过校验（不保存潜伏的
        # 非法配置）；返回错误行，raise 与否由调用方决定。
        def validate_snapshot_errors(snapshot : PolicySnapshot) : Array(String)
          errors = [] of String
          unless {"queue", "debounce"}.includes?(snapshot.batch_mode)
            errors << "batch_mode must be queue|debounce (got '#{snapshot.batch_mode}')"
          end
          unless {"sender", "session"}.includes?(snapshot.group_by)
            errors << "debounce.group_by must be sender|session (got '#{snapshot.group_by}')"
          end
          check_range(errors, "debounce.idle_ms", snapshot.idle_ms)
          check_range(errors, "debounce.max_wait_ms", snapshot.max_wait_ms)
          check_range(errors, "debounce.max_messages", snapshot.max_messages)
          check_range(errors, "debounce.max_bytes", snapshot.max_bytes)
          check_range(errors, "debounce.max_active_buckets", snapshot.max_active_buckets)
          check_range(errors, "steer.debounce_ms", snapshot.steer_debounce_ms)
          check_range(errors, "steer.max_pending_messages", snapshot.steer_max_pending_messages)
          check_range(errors, "steer.max_wait_ms", snapshot.steer_max_wait_ms)
          unless snapshot.max_wait_ms >= snapshot.idle_ms
            errors << "debounce.max_wait_ms must be >= debounce.idle_ms (#{snapshot.max_wait_ms} < #{snapshot.idle_ms})"
          end
          unless snapshot.steer_max_wait_ms >= snapshot.steer_debounce_ms
            errors << "steer.max_wait_ms must be >= steer.debounce_ms (#{snapshot.steer_max_wait_ms} < #{snapshot.steer_debounce_ms})"
          end
          errors << "queue.max_pending_batches must be positive (got #{snapshot.max_pending_batches})" unless snapshot.max_pending_batches > 0
          errors << "queue.max_pending_bytes must be positive (got #{snapshot.max_pending_bytes})" unless snapshot.max_pending_bytes > 0
          errors
        end

        private def check_range(errors : Array(String), label : String, value : Int64) : Nil
          range = RANGES[label]
          errors << "#{label} must be in #{range.begin}..#{range.end} (got #{value})" unless range.includes?(value)
        end
      end
    end
  end
end
