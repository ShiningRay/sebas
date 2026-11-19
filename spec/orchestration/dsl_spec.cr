require "spec"
require "../../src/orchestration/dsl/dsl"

def valid_workflow_yaml : String
  <<-YAML
    id: inbox-triage
    description: 工作邮箱收件分流摘要
    enabled: true
    trigger:
      type: event
      source: email.work-account.message.received
    actions:
      - id: notify
        tool: message.send
        args:
          channel: email
          peer: "me@example.com"
          content: "triaged"
        idempotency_key: "notify:${trigger.event_id}"
    YAML
end

module Sebas
  describe "orchestration DSL (M2-WP1)" do
    it "parses the design.md §7.6 example shape into typed workflow" do
      wf = ::Sebas::Orchestration::DSL::Parser.parse_workflow(valid_workflow_yaml)
      wf.id.should eq("inbox-triage")
      wf.trigger.type.should eq("event")
      wf.trigger.source.should eq("email.work-account.message.received")
      wf.actions.size.should eq(1)
      wf.actions.first.tool.should eq("message.send")
      wf.actions.first.idempotency_key.should contain("event_id")
      ::Sebas::Orchestration::DSL::Validator.validate(wf, ["main"]).should be_empty
    end

    it "parses the weekly-report cron + approval example" do
      wf = ::Sebas::Orchestration::DSL::Parser.parse_workflow(<<-YAML
        id: weekly-report
        trigger:
          type: cron
          schedule: "0 9 * * 1-5"
        actions:
          - id: send
            tool: message.send
            args: { channel: wecom, peer: "me", content: "report" }
            idempotency_key: "weekly:${trigger.scheduled_at}"
            approval: { mode: manual, timeout_seconds: 3600 }
        YAML
      )
      wf.trigger.schedule.should eq("0 9 * * 1-5")
      wf.actions.first.approval_mode.should eq("manual")
      wf.actions.first.approval_timeout.should eq(3600)
      ::Sebas::Orchestration::DSL::Validator.validate(wf, ["main"]).should be_empty
    end

    it "reports readable errors with line numbers for broken YAML" do
      expect_raises(::Sebas::Orchestration::DSL::DSLError, /line \d+/) do
        ::Sebas::Orchestration::DSL::Parser.parse_workflow("id: broken\n  actions: [oops\n")
      end
    end

    it "collects validation errors: unknown tool, missing idempotency, bad agent, dup ids" do
      wf = ::Sebas::Orchestration::DSL::Parser.parse_workflow(<<-YAML
        id: bad-wf
        trigger:
          type: cron
          schedule: "not a cron"
        actions:
          - id: a1
            tool: message.send
            args: { content: "x" }
          - id: a1
            tool: mystery.tool
          - id: a3
            tool: subagent.ask
            args: { agent: ghost }
          - id: a4
            tool: message.send
            args: { content: "y" }
            replay: maybe
          - id: a5
            tool: message.send
            approval: { mode: auto }
        YAML
      )
      errors = ::Sebas::Orchestration::DSL::Validator.validate(wf, ["main"])
      joined = errors.join("\n")
      joined.should contain("cron schedule must have 5 or 6 fields")
      joined.should contain("message.send requires idempotency_key")
      joined.should contain("duplicate action id")
      joined.should contain("unknown tool 'mystery.tool'")
      joined.should contain("targets unknown agent 'ghost'")
      joined.should contain("replay must be safe or effectful")
      joined.should contain("approval.mode must be manual/smart/off")
    end

    it "fails on missing required sections" do
      expect_raises(::Sebas::Orchestration::DSL::DSLError, /trigger is required/) do
        ::Sebas::Orchestration::DSL::Parser.parse_workflow("id: no-trigger\nactions: []\n")
      end
      expect_raises(::Sebas::Orchestration::DSL::DSLError, /id is required/) do
        ::Sebas::Orchestration::DSL::Parser.parse_workflow("trigger:\n  type: webhook\n  source: s\nactions: []\n")
      end
    end
  end
end
