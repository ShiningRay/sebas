require "json"
require "digest"
require "./hooks"
require "./hook_dispatcher"

# capability driver 装配（M3-WP5，#17；design.md §12.4 ③ §12.10）：
#
# 双重白名单落点——manifest.declares_capability?（WP4 已有）+ 宿主 driver
# 注册表（本文件）：capability 命中已声明 manifest 之后，还必须命中宿主
# 登记的 driver 才真正执行；未登记 = capability_driver_missing（与 WP4
# 行为一致，fail-closed）。
#
# scope 注入（§12.10「agent/账号 scope 由宿主注入」）：插件不可自带身份——
# driver 收到的 context 由宿主 runner 侧合成（plugin_id + capability 名域），
# 插件传参只允许 params。
#
# 受控 memory.backend（§6.2 §12.10）：MemoryDriver 提供 remember 查询写路径，
# 为 memory.remember.before/after 两 hook 的宿主注入点：写入前 gate+transform
# （deny/modify entry，宿主重新校验），提交成功后 observe（memory_id/kind/tags）。
# 后端为进程内最小存储（§6.2 业务记忆优先走宿主 Store 的过渡实现），
# 生产持久化由 memory.backend 选择机制（§12.7 enable 校验）后续接入。
module Sebas
  module Plugins
    # 宿主侧 driver 注册表：(plugin, capability, params, context,
    # idempotency_key) → JSON-like。idempotency_key 是请求级 task 重放身份
    # （可空——hook 路径无 task 身份），driver 据此派生重放 memo。
    # 线程安全：driver 内部自管。
    class CapabilityDispatcher
      Log = Hooks::Log

      alias DriverHandler = Proc(String, JSON::Any, JSON::Any, String?, JSON::Any)

      @drivers = Hash(String, DriverHandler).new
      @mutex = Mutex.new

      setter hook_bus : HookBus = HookBus.disabled

      def register(capability : String, &handler : String, JSON::Any, JSON::Any, String? -> JSON::Any) : Nil
        @mutex.synchronize { @drivers[capability] = handler }
      end

      def registered?(capability : String) : Bool
        @mutex.synchronize { @drivers.has_key?(capability) }
      end

      def dispatch(plugin_id : String, capability : String, params : JSON::Any,
                   context : JSON::Any, idempotency_key : String? = nil) : JSON::Any
        handler = @mutex.synchronize { @drivers[capability]? }
        unless handler
          raise CapabilityError.new("capability_driver_missing",
            "no driver registered for '#{capability}'")
        end
        handler.call(plugin_id, params, context, idempotency_key)
      rescue ex : CapabilityError
        raise ex
      rescue ex : ::Exception
        Log.error(exception: ex) { "driver failed: capability=#{capability} plugin=#{plugin_id}" }
        raise CapabilityError.new("capability_failed", (ex.message || "capability failed")[0, 500])
      end

      class CapabilityError < ::Exception
        getter code : String

        def initialize(@code : String, message : String)
          super(message)
        end
      end

      # 受控 memory.backend（§12.10）：remember 写路径 + memory.remember
      # 双 hook 注入点。写入后返回 memory_id；进程内存储，容量封顶。
      class MemoryDriver
        getter hook_bus : HookBus
        @entries = Hash(String, JSON::Any).new
        @mutex = Mutex.new
        MAX_ENTRIES = 4096

        def initialize(@hook_bus : HookBus = HookBus.disabled)
        end

        # 生产装配的幂等键派生（M3-WP5 review）：task 重放身份（replay_key，
        # 即工具面 idempotency_key）与 plugin_id、写入内容指纹**共同编码**——
        # 同 task 同内容重放命中同键（gate/write memo 一并复用）；不同 task
        # 写同内容不误并（各自独立写入）；无 task 身份（hook 路径）返回 nil
        # 不 memo。
        def self.idempotency_key(replay_key : String?, plugin_id : String,
                                 params : JSON::Any) : String?
          return unless replay_key
          "memory_driver.write:#{replay_key}:#{plugin_id}:#{Digest::SHA256.hexdigest(params.to_json)}"
        end

        def entries
          @mutex.synchronize { @entries.dup }
        end

        # capability "memory_driver.write"：params {kind, text, tags}。
        # 写前 gate+transform（entry 可 deny/modify，宿主重校验）；提交成功后
        # observe（memory_id/kind/tags）。幂等重放：同 key 返回同 memory_id、
        # 不重复写入（#17 验收「task 重放 memo 不重复副作用」）。
        @idempotency = Hash(String, String).new

        # ameba:disable Metrics/CyclomaticComplexity — 幂等查表+双重授权+终态登记的状态机，分支即语义
        def write(plugin_id : String, params : JSON::Any, context : JSON::Any,
                  hook_bus : HookBus = @hook_bus, idempotency_key : String? = nil) : JSON::Any
          # 幂等重放查表先于 before hook（M3-WP5 review）：已提交的同 key
          # 重放直接返回既有 memory_id——不重跑 before hook；重载后新总线的
          # hook memo 为空、可能拒绝同 key 重放，但已提交承诺不受影响（同 key
          # 同 memory_id 契约）。提交临界区内仍有并发复查。
          if key = idempotency_key
            existing_id = @mutex.synchronize { @idempotency[key]? }
            if existing_id
              return JSON.parse(%({"ok": true, "memory_id": #{existing_id.to_json}}))
            end
          end
          entry = JSON.parse(JSON.build do |json|
            json.object do
              json.field "kind", params["kind"]?.try(&.as_s?) || "memory"
              json.field "text", params["text"]?.try(&.as_s?) || ""
              json.field "tags", params["tags"]?.try(&.as_a?).try(&.map(&.as_s?)) || [] of String
            end
          end)
          # transform 路径（M3-WP5 review）：gate 的 interpret 对裸返回值不
          # 替换——DSL modify! 的修改会被丢弃；gate_transform 用 transform
          # 派发（deny 与替换重校验同路径）
          verdict = hook_bus.transform("memory.remember.before", context,
            JSON.parse(%({"entry": #{entry.to_json}})), idempotency_key: idempotency_key)
          if verdict.denied
            return JSON.parse({ok: false, error: "#{verdict.code}: #{verdict.reason}"}.to_json)
          end
          resolved = verdict.payload.try(&.as_h?).try(&.[]?("entry")) || entry
          # 最终字段在提交前定形（M3-WP5 review）：非字符串标签元素就地过滤
          # ——否则提交成功但 after payload 被 StrArray 契约拒绝，订阅者收
          # 不到成功通知而调用方已拿到 ok:true
          final_entry = JSON.parse(JSON.build do |json|
            json.object do
              json.field "kind", resolved["kind"]?.try(&.as_s?) || "memory"
              json.field "text", resolved["text"]?.try(&.as_s?) || ""
              json.field "tags", resolved["tags"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
            end
          end)
          tags = final_entry["tags"].as_a.map(&.as_s)

          memory_id = "mem-#{Random::Secure.hex(8)}"
          stored = JSON.parse(JSON.build do |json|
            json.object do
              json.field "memory_id", memory_id
              json.field "kind", final_entry["kind"]?.try(&.as_s?) || "memory"
              json.field "text", final_entry["text"]?.try(&.as_s?) || ""
              json.field "tags", tags # 条目与 after payload 同源（M3-WP5 review）
              json.field "plugin_id", plugin_id
            end
          end)
          @mutex.synchronize do
            # 临界区内幂等复查（M3-WP5 review）：并发同 key 调用只有一个
            # 插入+observe，其余返回首个写入者的 memory_id——检查与提交
            # 同一临界区，两侧不隔锁
            if key = idempotency_key
              if prior_id = @idempotency[key]?
                return JSON.parse(%({"ok": true, "memory_id": #{prior_id.to_json}}))
              end
            end
            if @entries.size >= MAX_ENTRIES
              raise CapabilityError.new("memory_overflow", "memory driver store cap (#{MAX_ENTRIES}) reached")
            end
            @entries[memory_id] = stored
            # 幂等键登记（提交成功后，同临界区）；首个写入者持有 id
            @idempotency[idempotency_key] = memory_id if idempotency_key
          end
          # 提交成功后 observe（§12.11：失败或 deny 不触发 after）
          kind = stored["kind"]?.try(&.as_s?) || "memory"
          after = JSON.parse(JSON.build do |json|
            json.object do
              json.field "memory_id", memory_id
              json.field "kind", kind
              json.field "tags", tags
            end
          end)
          hook_bus.observe("memory.remember.after", context, after)
          JSON.parse(%({"ok": true, "memory_id": #{memory_id.to_json}}))
        end
      end
    end
  end
end
