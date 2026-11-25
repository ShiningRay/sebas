require "json"
require "./gateway_dispatch"
require "../../sessions/scheduling/policy"
require "../../log"

module Sebas
  module Platform
    module CLI
      # 调度参数管理面（M4.5-WP6）：config.scheduling get/validate/update/reset
      # （effective 预览 / expected_revision 防并发 / 审计 / reset 继承恢复）+
      # sessions.queue.get/flush + sessions.steer.get + metrics.scheduling。
      # IPC 与 HTTP 双入口共用 handle_scheduling_admin（语义一致）。
      module GatewaySchedulingAdmin
        Log = Sebas::Log.for("sebas.gateway")

        # effective snapshot：builtin → gateway.session → gateway overlay →
        # agents.<name>.session → agent overlay（overlay 持久表，热更新不重启）
        def effective_snapshot(session_key : String? = nil) : Sessions::Scheduling::PolicySnapshot
          config = Config::CURRENT.get
          gateway_overlay = overlay_config("gateway")
          unless session_key
            # gateway 层预览：不混入任何 agent 的 session/overlay（gzi7）
            return Sessions::Scheduling::Policy.resolve_session_with_overlays(
              config.gateway.try(&.session), nil, gateway_overlay, nil
            )
          end
          agent_name = session_key.split(":")[1]? || "main"
          agent_cfg = config.agents[agent_name]?
          agent_overlay = overlay_config("agent:#{agent_name}")
          Sessions::Scheduling::Policy.resolve_session_with_overlays(
            config.gateway.try(&.session), agent_cfg.try(&.session), gateway_overlay, agent_overlay
          )
        end

        private def overlay_config(scope : String) : Sessions::Scheduling::SessionPolicyConfig?
          row = @store.scheduling_overlay(scope)
          row ? Sessions::Scheduling::Policy.parse_overlay(row.patch_yaml) : nil
        rescue ex : Sessions::Scheduling::PolicyError
          Log.error(exception: ex) { "overlay unparsable, ignored (scope=#{scope})" }
          nil
        end

        # 统一入口（IPC/HTTP 同语义）：command ∈ config.scheduling.get/validate/
        # update/reset、sessions.queue.get/flush、sessions.steer.get、
        # metrics.scheduling。params 字段随命令。
        def handle_scheduling_admin(command : String, params : ::JSON::Any) : Tuple(Int32, String)
          case command
          when "config.scheduling.get"      then scheduling_preview
          when "config.scheduling.validate" then scheduling_validate(params)
          when "config.scheduling.update"   then scheduling_update(params)
          when "config.scheduling.reset"    then scheduling_reset(params)
          when "sessions.queue.get"         then queue_get(param(params, "session_key"))
          when "sessions.queue.flush"       then queue_flush(param(params, "session_key"))
          when "sessions.steer.get"         then steer_get(param(params, "session_key"))
          when "metrics.scheduling"         then scheduling_metrics
          else
            {404, %({"error": "unknown scheduling command"})}
          end
        end

        # IPC/HTTP 双入口接线（gateway 构造调用）+ SSE 状态迁移事件桥（M4.5-WP6）：
        # 批次/steer/config.scheduling 迁移 → tap
        def wire_scheduling_admin : Nil
          handler = ->(command : String, params : ::JSON::Any) { handle_scheduling_admin(command, params) }
          @ipc.scheduling_admin_handler = handler
          @http.scheduling_admin_handler = handler
          tap_bridge = ->(event : String, payload : ::JSON::Any) do
            @ipc.tap.publish(Admin::IPC.event_line(event, payload.as_h))
          end
          @scheduling.on_transition = tap_bridge
          @steer_center.on_transition = tap_bridge
        end

        private def param(params : ::JSON::Any, key : String) : String
          params[key]?.try(&.as_s?) || ""
        end

        # effective 预览（gateway + 全 agents 各自 resolve，含 overlay）
        private def scheduling_preview : Tuple(Int32, String)
          config = Config::CURRENT.get
          gateway = snapshot_json(effective_snapshot(nil))
          agents = config.agents.keys.sort!.map do |name|
            {name => snapshot_json(effective_snapshot("agent:#{name}:webhook:hooks"))}
          end
          {200, {
            revision: @store.scheduling_revision,
            overlays: @store.scheduling_overlays.map do |row|
              {scope: row.scope, revision: row.revision, operator: row.operator, updated_at: row.updated_at}
            end,
            effective: {gateway: gateway, agents: agents},
          }.to_json}
        end

        private def snapshot_json(snapshot : Sessions::Scheduling::PolicySnapshot) : ::JSON::Any
          JSON.parse(snapshot.to_json)
        end

        # validate：patch 文本解析 + 候选 overlay 置入**实际生效链**校验
        # （目标 agent 层 + 其它已存 overlay——gzjD；不落表）
        private def scheduling_validate(params : ::JSON::Any) : Tuple(Int32, String)
          yaml = params["yaml"]?.try(&.as_s?) || ""
          scope = params["scope"]?.try(&.as_s?) || "gateway"
          begin
            patch = Sessions::Scheduling::Policy.parse_overlay(yaml)
            cfg = Config::CURRENT.get
            if scope.starts_with?("agent:") && cfg.agents[scope.lchop("agent:")]?.nil?
              return {400, %({"valid": false, "errors": ["unknown agent #{scope.lchop("agent:")}"]})}
            end
            validate_candidate(scope, patch, cfg)
            emit_scheduling_event("config.scheduling.validated", scope)
            {200, %({"valid": true})}
          rescue ex : Sessions::Scheduling::PolicyError
            {400, {valid: false, errors: ex.message.to_s.lines}.to_json}
          end
        end

        # 候选 overlay 置入实际层级链校验：gateway scope 校验 gateway+全部 agent；
        # agent scope 校验该 agent（既有 overlays 全部保留参与合并——gzjD）
        private def validate_candidate(scope : String, patch : Sessions::Scheduling::SessionPolicyConfig?,
                                       cfg : Config::Config) : Nil
          gateway_overlay = scope == "gateway" ? patch : overlay_config("gateway")
          if scope == "gateway"
            # gateway overlay 变化影响全部 agent：gateway 链 + 每个 agent 链都验
            Sessions::Scheduling::Policy.resolve_session_with_overlays(
              cfg.gateway.try(&.session), nil, gateway_overlay, nil
            )
            cfg.agents.keys.each do |name|
              agent_overlay = overlay_config("agent:#{name}") || (scope.starts_with?("agent:") ? patch : nil)
              Sessions::Scheduling::Policy.resolve_session_with_overlays(
                cfg.gateway.try(&.session), cfg.agents[name]?.try(&.session), gateway_overlay, agent_overlay
              )
            end
          else
            agent_name = scope.lchop("agent:")
            agent_overlay = patch
            Sessions::Scheduling::Policy.resolve_session_with_overlays(
              cfg.gateway.try(&.session), cfg.agents[agent_name]?.try(&.session), gateway_overlay, agent_overlay
            )
          end
        end

        # ameba:disable Metrics/CyclomaticComplexity — 冲突/校验/原子落表/一次性 flush 直译
        private def scheduling_update(params : ::JSON::Any) : Tuple(Int32, String)
          scope = params["scope"]?.try(&.as_s?) || "gateway"
          yaml = params["yaml"]?.try(&.as_s?) || ""
          operator = params["operator"]?.try(&.as_s?) || "admin"
          expected = params["expected_revision"]?.try(&.as_i64?)
          current = @store.scheduling_revision
          if expected && expected != current
            return {409, {error: "revision conflict", expected: expected,
                          current: current}.to_json}
          end
          begin
            patch = Sessions::Scheduling::Policy.parse_overlay(yaml)
            cfg = Config::CURRENT.get
            if scope.starts_with?("agent:") && cfg.agents[scope.lchop("agent:")]?.nil?
              return {400, %({"error": "unknown agent #{scope.lchop("agent:")}"})}
            end
            unless {"gateway"}.includes?(scope) || scope.starts_with?("agent:")
              return {400, %({"error": "scope must be gateway or agent:<name>"})}
            end
            validate_candidate(scope, patch, cfg)
          rescue ex : Sessions::Scheduling::PolicyError
            # 非法范围拒绝：旧配置继续工作（不落表）
            emit_scheduling_event("config.scheduling.rejected", scope)
            return {400, {error: "invalid patch", errors: ex.message.to_s.lines}.to_json}
          end
          revision = @store.upsert_scheduling_overlay(scope, yaml, operator,
            expected_revision: expected)
          unless revision # 原子冲突（并发覆盖）——409
            return {409, {error: "revision conflict", expected: expected,
                          current: @store.scheduling_revision}.to_json}
          end
          emit_scheduling_event("config.scheduling.applied", scope)
          # 一次性 flush_on_policy_change（gzjW）：管理操作非持久配置——
          # debounce→queue 切换后立即收敛全部 collecting 桶
          if params["flush_on_policy_change"]?.try(&.as_bool?) == true
            @store.scheduled_session_keys.each { |session| @scheduling.flush_session(session) }
          end
          {200, {revision: revision, scope: scope}.to_json}
        end

        # reset：删 overlay 恢复上一层继承（非写死内置值）。删除前校验恢复后
        # 的完整策略（跨 overlay 交互——gzje），无效保留原 overlay 返回校验错误
        private def scheduling_reset(params : ::JSON::Any) : Tuple(Int32, String)
          scope = params["scope"]?.try(&.as_s?) || "gateway"
          expected = params["expected_revision"]?.try(&.as_i64?)
          current = @store.scheduling_revision
          if expected && expected != current
            return {409, {error: "revision conflict", expected: expected, current: current}.to_json}
          end
          begin
            cfg = Config::CURRENT.get
            nil_cfg = nil
            validate_candidate(scope, nil_cfg, cfg) # 删除后候选 = 无该 overlay
          rescue ex : Sessions::Scheduling::PolicyError
            return {400, {error:  "reset would produce invalid policy",
                          errors: ex.message.to_s.lines}.to_json}
          end
          new_revision = @store.delete_scheduling_overlay(scope, expected_revision: expected)
          if expected && new_revision.nil?
            return {409, {error: "revision conflict", expected: expected,
                          current: @store.scheduling_revision}.to_json}
          end
          emit_scheduling_event("config.scheduling.applied", scope)
          {200, {scope: scope, revision: new_revision}.to_json} # 数值（客户端复用 expected_revision，qijV）
        end

        private def emit_scheduling_event(event : String, scope : String) : Nil
          @ipc.tap.publish(Admin::IPC.event_line(event, {"scope" => ::JSON::Any.new(scope)}))
        end

        # 队列概览（持久状态为准——事件流非权威存储）
        private def queue_get(session_key : String) : Tuple(Int32, String)
          return {400, %({"error": "session_key is required"})} if session_key.empty?
          {200, {
            session_key: session_key,
            batches:     @store.session_batches_by_session(session_key).map do |b|
              {batch_id: b.batch_id, status: b.status, seal_reason: b.seal_reason}
            end,
            in_flight:    @scheduling.in_flight_batch(session_key),
            pending_load: @scheduling.pending_load(session_key),
          }.to_json}
        end

        # flush：collecting 桶强制封冻 + 立即派发（debounce→queue 切换的一次性收敛）
        private def queue_flush(session_key : String) : Tuple(Int32, String)
          return {400, %({"error": "session_key is required"})} if session_key.empty?
          sealed = @scheduling.flush_session(session_key)
          {200, {session_key: session_key, sealed_buckets: sealed}.to_json}
        end

        private def steer_get(session_key : String) : Tuple(Int32, String)
          return {400, %({"error": "session_key is required"})} if session_key.empty?
          rows = @store.session_steers(session_key)
          counts = {} of String => Int32
          rows.each { |steer| counts[steer.status] = (counts[steer.status]? || 0) + 1 }
          {200, {
            session_key: session_key,
            counts:      counts,
            steers:      rows.map do |steer|
              {steer_id: steer.steer_id, status: steer.status, reason: steer.reason,
               target_turn_id: steer.target_turn_id, target_generation: steer.target_generation,
               created_at: steer.created_at}
            end,
          }.to_json}
        end

        # 指标聚合（内存计数器 + 持久聚合）
        private def scheduling_metrics : Tuple(Int32, String)
          sessions = (@store.session_keys + @store.scheduled_session_keys).uniq
          counters = sessions.map do |session|
            {session_key: session, metrics: @scheduling.session_metrics(session)}
          end
          steer_counts = Hash(String, Int32).new(0)
          recovery_batches = 0
          # steer 统计走全表（/steer 短路不经 admission，会话可能无 touch 记录）
          @store.steers_all.each do |steer|
            steer_counts[steer.status] += 1
          end
          sessions.each do |session|
            recovery_batches += @store.session_batches_by_session(session).count do |batch|
              batch.seal_reason == "recovery"
            end
          end
          {200, {
            scheduler_counters: counters,
            steer_by_status:    steer_counts,
            recovery_batches:   recovery_batches,
          }.to_json}
        end
      end
    end
  end
end
