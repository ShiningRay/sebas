require "json"
require "./gateway_dispatch"
require "../../sessions/scheduling/steer"
require "../../sessions/scheduling/policy"
require "../../log"

module Sebas
  module Platform
    module CLI
      # webhook 会话接入（M4.5-WP5，自 gateway 拆分）：/hooks/<name> 提交面
      # （持久 admission → 202 快速返回）+ hooks 会话批次执行（逐事件 fire
      # 或显式批量合成一个 run）。include mixin，实例变量由宿主 Gateway 提供
      # （@store/@config/@triggers/@engine/@scheduling/@lifecycle_store）。
      module GatewayHooks
        Log = Sebas::Log.for("sebas.gateway")

        # hooks 提交回执（HTTP 层透传 code/body，类型零耦合）
        record HookReceipt, code : Int32, body : String

        # 会话路由（M4.5-WP5）：同一 hook 复用会话（peer 段 = hook 名），
        # 不同 hook 不串会话；channel 段固定 "hooks" 供 run_batch_job 分流
        # workflow YAML 装载（data_dir/workflows/*.yaml）：目录不存在即空
        # （向后兼容，无 workflow 部署时行为不变）；装载失败单文件 fail-logged
        # 不阻断其余
        private def load_workflows : Nil
          workflow_dir = @data_dir / "workflows"
          return unless Dir.exists?(workflow_dir)
          # Dir.children + Path 拼接（glob 反斜杠模式 windows 不匹配——
          # windows CI 实测 workflow 全部漏载）
          files = Dir.children(workflow_dir).select(&.ends_with?(".yaml")).sort!
          files.each do |file|
            @engine.register(Orchestration::DSL::Parser.parse_workflow(File.read(workflow_dir / file)))
          rescue ex
            Log.error(exception: ex) { "workflow load failed: #{file}" }
          end
          @triggers.load_from_registry
        end

        # HTTP hook_handler 接线（gateway 构造调用）：回执转 (code, body)
        def wire_hook_handler : Nil
          @http.hook_handler = ->(name : String, payload : String, key : String?) do
            receipt = handle_hook_submission(name, payload, key)
            {receipt.code, receipt.body}
          end
        end

        private def hook_session_key(name : String) : String
          "agent:main:hooks:webhook:#{name}"
        end

        # /hooks/<name> 提交（任务书范围①③）：查 workflow（未知 fail-closed
        # 404）→ Idempotency-Key 派生 event_id（缺省服务端一次接收 ID，不宣称
        # 跨重试去重）→ hook 会话持久 admit → 202 + event_id/batch_id 快速
        # 返回（事务与容量检查在回调时间预算内）；容量满 429 可重试明确错误。
        private def handle_hook_submission(name : String, payload : String,
                                           idempotency_key : String?) : HookReceipt
          return HookReceipt.new(404, %({"error": "unknown hook"})) unless @triggers.webhook?(name)
          key = idempotency_key.try(&.strip).presence || "recv-#{::Random::Secure.hex(8)}"
          event_id = "webhook:#{name}:#{key}"
          session_key = hook_session_key(name)
          workflow = hook_workflow(name)
          snapshot = Sessions::Scheduling::Policy.resolve_workflow(workflow.try(&.batch))
          envelope = Sessions::Scheduling::InputEnvelope.new(
            event_id, session_key, "webhook", "hooks", 0, ::Time.utc.to_rfc3339, nil,
            Bus::InboundMessage.new(event_id, "hooks", "webhook", name, payload).to_json,
            snapshot
          )
          receipt = scheduling.admit(envelope)
          # touch 失败不改 admission 结果（事件已受理；仅元数据缺失）
          if receipt.status == "accepted"
            begin
              @lifecycle_store.touch(session_key, "main", "user")
            rescue ex
              Log.warn(exception: ex) { "hooks lifecycle touch failed (event=#{event_id})" }
            end
          end
          Log.info { "hook admitted (hook=#{name} event=#{event_id} status=#{receipt.status} batch=#{receipt.batch_id})" }
          case receipt.status
          when "accepted", "duplicate"
            HookReceipt.new(202, {event_id: event_id, batch_id: receipt.batch_id,
                                  status: receipt.status}.to_json)
          else
            # 容量满：可重试明确错误（fail-closed 不排队）
            HookReceipt.new(429, {event_id: event_id, error: "capacity exceeded",
                                  retryable: true}.to_json)
          end
        end

        # hooks 会话批次执行（run_batch_job 分流，任务书范围④）：确定性
        # workflow 默认逐事件一 run；显式 batch 配置合成一个 run——payload
        # 记录 batch_id 与全部 event IDs（batch→run→events 完整审计）。
        # 返回失败 event_ids（batch_done 收敛口径与聊天路径一致）。
        private def run_hooks_batch(session_key : String, batch_id : String,
                                    inputs : Array(::Sebas::Platform::Store::Store::SessionInputRow)) : Array(String)
          name = session_key.split(":", 5)[4]? || ""
          workflow = hook_workflow(name)
          failed = [] of String
          unless workflow
            Log.error { "hooks batch without workflow (hook=#{name} batch=#{batch_id})" }
            return inputs.map(&.event_id)
          end
          if workflow.batch # 显式批量：一个 run 收整批
            event_ids = inputs.map(&.event_id)
            head = event_ids.first
            started = @engine.start(workflow, head, batch_id, event_ids) != nil
            event_ids.each do |eid|
              @store.record_intent(eid, "message", inputs.find(&.event_id.==(eid)).try(&.payload) || "")
              @store.finish_intent(eid, started ? "done" : "failed")
              failed << eid unless started
            end
            return failed
          end
          # 默认逐事件：一事件一 run（run_id 含 event_id，record_intent 幂等防重跑）
          inputs.each do |input|
            msg = message_from_payload(input.payload)
            @store.record_intent(msg.event_id, "message", input.payload)
            ok = @triggers.fire_webhook(name, msg.content, msg.event_id)
            @store.finish_intent(msg.event_id, ok ? "done" : "failed")
            failed << msg.event_id unless ok
            Log.info { "hook event fired (hook=#{name} event=#{msg.event_id} ok=#{ok})" }
          end
          failed
        end

        private def hook_workflow(name : String) : ::Sebas::Orchestration::DSL::Workflow?
          @engine.workflows.values.find do |workflow|
            workflow.trigger.type == "webhook" && workflow.trigger.source == name
          end
        end
      end
    end
  end
end
