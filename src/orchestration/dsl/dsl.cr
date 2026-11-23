require "yaml"
require "json"
require "../../log"
require "../../sessions/scheduling/policy"

# 编排 DSL（M2-WP1，design.md §7.6）：触发→条件→动作 YAML 解析与校验。
# v1 条件不做图灵完备（§15.3.21）：仅声明式谓词（元数据匹配 + all/any/not 组合）。
module Sebas
  module Orchestration
    module DSL
      class DSLError < ::Exception; end

      class ValidationError < DSLError
        getter errors : Array(String)

        def initialize(@errors)
          super("workflow validation failed:\n" + @errors.map { |e| "  - #{e}" }.join("\n"))
        end
      end

      record Trigger, type : String, schedule : String, source : String
      record Action, id : String, tool : String, args : String, replay : String,
        idempotency_key : String, approval_mode : String, approval_timeout : Int32
      record Workflow, id : String, description : String, enabled : Bool,
        trigger : Trigger, actions : Array(Action),
        batch : ::Sebas::Sessions::Scheduling::SessionPolicyConfig?

      module Parser
        extend self

        def parse_workflow(raw : String) : Workflow
          doc = YAML.parse(raw)
          from_node(doc)
        rescue ex : YAML::ParseException
          raise DSLError.new("invalid workflow YAML: #{ex.message}") # 消息自带行号
        end

        def from_node(doc : YAML::Any) : Workflow
          id = doc["id"]?.try(&.as_s?)
          raise DSLError.new("workflow.id is required") if id.nil? || id.empty?
          trigger_node = doc["trigger"]?
          raise DSLError.new("workflow.#{id}.trigger is required") unless trigger_node
          trigger = parse_trigger(trigger_node, id)
          actions_node = doc["actions"]?
          actions_list = actions_node.try(&.as_a?)
          raise DSLError.new("workflow.#{id}.actions is required") unless actions_list
          actions = actions_list.map_with_index { |a, i| parse_action(a, id, i) }
          Workflow.new(
            id, doc["description"]?.try(&.as_s?) || "",
            doc["enabled"]?.try(&.as_bool?) != false,
            trigger, actions, parse_batch(doc, id)
          )
        end

        private def parse_batch(doc : YAML::Any, wf_id : String) : ::Sebas::Sessions::Scheduling::SessionPolicyConfig?
          node = doc["batch"]?
          return unless node
          begin
            ::Sebas::Sessions::Scheduling::SessionPolicyConfig.from_any(node)
          rescue ex : ::Sebas::Sessions::Scheduling::PolicyError
            raise DSLError.new("workflow.#{wf_id}.batch: #{ex.message}")
          end
        end

        private def parse_trigger(node : YAML::Any, wf_id : String) : Trigger
          type = node["type"]?.try(&.as_s?) || ""
          unless {"cron", "event", "webhook", "account"}.includes?(type)
            raise DSLError.new("workflow.#{wf_id}.trigger.type must be cron/event/webhook/account (got '#{type}')")
          end
          schedule = node["schedule"]?.try(&.as_s?) || ""
          source = node["source"]?.try(&.as_s?) || ""
          if type == "cron" && schedule.empty?
            raise DSLError.new("workflow.#{wf_id}.trigger.schedule is required for cron")
          end
          if {"event", "webhook", "account"}.includes?(type) && source.empty?
            raise DSLError.new("workflow.#{wf_id}.trigger.source is required for #{type}")
          end
          Trigger.new(type, schedule, source)
        end

        private def parse_action(node : YAML::Any, wf_id : String, index : Int32) : Action
          tag = "workflow.#{wf_id}.actions[#{index}]"
          id = node["id"]?.try(&.as_s?) || ""
          raise DSLError.new("#{tag}.id is required") if id.empty?
          tool = node["tool"]?.try(&.as_s?) || ""
          raise DSLError.new("#{tag}.tool is required") if tool.empty?
          args_node = node["args"]?
          args_json = "{}"
          if args_node
            buffer = IO::Memory.new
            builder = ::JSON::Builder.new(buffer)
            builder.start_document
            args_node.to_json(builder)
            builder.end_document
            builder.flush
            rendered = buffer.to_s
            args_json = rendered == "null" ? "{}" : rendered
          end
          approval = node["approval"]?
          approval_mode = approval.try(&.["mode"]?).try(&.as_s?) || ""
          approval_timeout = approval.try(&.["timeout_seconds"]?).try(&.as_i?) || 300
          Action.new(
            id, tool,
            args_json,
            node["replay"]?.try(&.as_s?) || "",
            node["idempotency_key"]?.try(&.as_s?) || "",
            approval_mode, approval_timeout.to_i32
          )
        end
      end

      module Validator
        extend self

        KNOWN_TOOLS = %w[message.send memory.search memory.save session.read subagent.ask fork join]

        # 纯函数校验（热更新复用口径）：返回错误列表，空=合法
        def validate(workflow : Workflow, agent_names : Enumerable(String)) : Array(String)
          errors = [] of String
          agents = agent_names.to_a
          validate_trigger(workflow, errors)
          validate_actions(workflow, agents, errors)
          validate_batch(workflow, errors)
          errors
        end

        # workflow.batch 覆盖校验（session-input-scheduling.md §3.1：workflow 作用域
        # 不继承 gateway.session / agents.*.session；显式字段仍过硬范围校验）
        private def validate_batch(workflow : Workflow, errors : Array(String)) : Nil
          return unless wf_batch = workflow.batch
          begin
            ::Sebas::Sessions::Scheduling::Policy.resolve_workflow(wf_batch)
          rescue ex : ::Sebas::Sessions::Scheduling::PolicyError
            ex.message.to_s.lines.select(&.strip.starts_with?("- ")).each do |line|
              errors << "workflow.#{workflow.id}.batch: #{line.strip.lchop("- ").strip}"
            end
          end
        end

        private def validate_trigger(workflow : Workflow, errors : Array(String)) : Nil
          return unless workflow.trigger.type == "cron"
          # 最小 cron 合法性：5 或 6 字段
          fields = workflow.trigger.schedule.split(" ", remove_empty: true)
          unless {"5", "6"}.includes?(fields.size.to_s)
            errors << "workflow.#{workflow.id}: cron schedule must have 5 or 6 fields"
          end
        end

        private def validate_actions(workflow : Workflow, agents : Array(String), errors : Array(String)) : Nil
          seen = Set(String).new
          workflow.actions.each do |action|
            tag = "workflow.#{workflow.id}.actions[#{action.id}]"
            errors << "#{tag}: duplicate action id" unless seen.add?(action.id)
            unless {"safe", "effectful", ""}.includes?(action.replay)
              errors << "#{tag}: replay must be safe or effectful (got '#{action.replay}')"
            end
            unless {"", "manual", "smart", "off"}.includes?(action.approval_mode)
              errors << "#{tag}: approval.mode must be manual/smart/off"
            end
            if action.tool == "subagent.ask"
              agent = workflow_action_agent(action)
              unless agent.empty? || agents.includes?(agent)
                errors << "#{tag}: subagent.ask targets unknown agent '#{agent}' (available: #{agents.join(",")})"
              end
            elsif !KNOWN_TOOLS.includes?(action.tool) && !action.tool.starts_with?("plugin.")
              errors << "#{tag}: unknown tool '#{action.tool}'"
            end
            # 发消息类动作必须带幂等键或可派生（§7.3：不重发）
            if action.tool == "message.send" && action.idempotency_key.empty?
              errors << "#{tag}: message.send requires idempotency_key"
            end
          end
        end

        private def workflow_action_agent(action : Action) : String
          parsed = JSON.parse(action.args)
          parsed["agent"]?.try(&.as_s?) || ""
        rescue ::Exception
          ""
        end
      end
    end
  end
end
