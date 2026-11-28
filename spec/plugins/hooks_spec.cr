require "spec"
require "../../src/plugins/hooks"

# 钩子目录与 payload 契约验收（M3-WP5，#17；design.md §12.11 首版闭集 22 个）。
module Sebas
  module Plugins
    describe "hooks catalog（M3-WP5 §12.11 闭集）" do
      it "恰好 22 个钩子，gateway.start/stop 是两个独立名称" do
        Hooks.names.size.should eq(22)
        Hooks.definition?("gateway.start").should_not be_nil
        Hooks.definition?("gateway.stop").should_not be_nil
      end

      it "八域齐全：消息 3 / Agent 2 / LLM 4 / 工具 3 / 会话 4 / 记忆 2 / 任务 2 / 平台 2" do
        domains = Hash(String, Int32).new
        Hooks.names.each do |name|
          domain = name.split(".").first
          domains[domain] = (domains[domain]? || 0) + 1
        end
        domains["message"].should eq(3)
        domains["agent"].should eq(2)
        domains["llm"].should eq(4)
        domains["tool"].should eq(3)
        domains["session"].should eq(4)
        domains["memory"].should eq(2)
        domains["task"].should eq(2)
        domains["gateway"].should eq(2)
      end

      it "kind 契约：文档逐行对齐（gate/gate_transform/transform/observe）" do
        Hooks.definition!("message.sending").kind.gate_transform?.should be_true
        Hooks.definition!("agent.turn.before").kind.gate?.should be_true
        Hooks.definition!("llm.request.before").kind.gate_transform?.should be_true
        Hooks.definition!("llm.response.transform").kind.transform?.should be_true
        Hooks.definition!("tool.call.before").kind.gate_transform?.should be_true
        Hooks.definition!("tool.result.transform").kind.transform?.should be_true
        Hooks.definition!("memory.remember.before").kind.gate_transform?.should be_true
        Hooks.definition!("message.received").kind.observe?.should be_true
        Hooks.definition!("message.sent").kind.observe?.should be_true
        Hooks.definition!("agent.turn.after").kind.observe?.should be_true
        Hooks.definition!("gateway.start").kind.observe?.should be_true
      end

      it "文档列明字段的行：键与类型逐字段精确（宿主不得臆加未列字段）" do
        sent = Hooks.definition!("message.sent")
        sent.fields.keys.sort!.should eq(["error_code", "message_id", "status"])
        sent.fields["status"].values.should eq(%w[success error])
        sent.fields["message_id"].nullable.should be_true
        sent.fields["error_code"].nullable.should be_true

        tool_after = Hooks.definition!("tool.call.after")
        tool_after.fields.keys.sort!.should eq(
          ["duration_ms", "request_id", "result_summary", "session_key", "status", "tool_id"])
        tool_after.fields["status"].values.should eq(%w[success error exception])

        mem_after = Hooks.definition!("memory.remember.after")
        mem_after.fields.keys.sort!.should eq(["kind", "memory_id", "tags"])
        mem_after.fields["tags"].type.str_array?.should be_true

        task_start = Hooks.definition!("task.start")
        task_start.fields.keys.sort!.should eq(["run_id", "workflow_id"])

        task_end = Hooks.definition!("task.end")
        task_end.fields.keys.sort!.should eq(["error", "status", "task_id"])
        task_end.fields["error"].optional.should be_true
      end

      it "敏感 hook 标注：含消息/参数/文本的 hook 要求 hooks.sensitive" do
        Hooks.definition!("message.sending").sensitive.should be_true
        Hooks.definition!("llm.response.transform").sensitive.should be_true
        Hooks.definition!("tool.call.before").sensitive.should be_true
        Hooks.definition!("tool.result.transform").sensitive.should be_true
        Hooks.definition!("memory.remember.before").sensitive.should be_true
        Hooks.definition!("session.compact.after").sensitive.should be_true # 摘要文本（M3-WP5 review）
        Hooks.definition!("llm.request.before").sensitive.should be_true
        Hooks.definition!("message.received").sensitive.should be_false
        Hooks.definition!("tool.call.after").sensitive.should be_false
      end

      it "未知钩子不在目录：definition? 返回 nil，definition! 抛 SchemaError" do
        Hooks.definition?("free_form.anything").should be_nil
        expect_raises(Hooks::SchemaError) { Hooks.definition!("free_form.anything") }
      end
    end

    describe "payload schema 校验" do
      it "合法 payload 通过（含 optional 键省略）" do
        payload = JSON.parse(%({"status": "success", "message_id": "m-1", "error_code": null}))
        Hooks.validate_payload!("message.sent", payload).should be_nil
        # 列出字段即必需键：宿主须带全键集，缺失即 payload 契约违约
        payload = JSON.parse(%({"status": "error", "message_id": null, "error_code": "E_TIMEOUT"}))
        Hooks.validate_payload!("message.sent", payload).should be_nil
        payload = JSON.parse(%({"status": "error"}))
        expect_raises(Hooks::SchemaError, /missing key/) do
          Hooks.validate_payload!("message.sent", payload)
        end
      end

      it "未声明键拒绝（键集闭）" do
        payload = JSON.parse(%({"status": "success", "raw_body": "..."}))
        expect_raises(Hooks::SchemaError, /undeclared key/) do
          Hooks.validate_payload!("message.sent", payload)
        end
      end

      it "缺必需键拒绝" do
        payload = JSON.parse(%({"status": "success"}))
        expect_raises(Hooks::SchemaError, /missing key/) do
          Hooks.validate_payload!("tool.call.after", payload)
        end
      end

      it "枚举值越界拒绝" do
        payload = JSON.parse(%({"status": "maybe"}))
        expect_raises(Hooks::SchemaError, /must be one of/) do
          Hooks.validate_payload!("message.sent", payload)
        end
      end

      it "类型不符拒绝（int 给 string）" do
        payload = JSON.parse(%({"tool_id": "t","request_id": "r","session_key": "s","status": "success","duration_ms": "fast","result_summary": "x"}))
        expect_raises(Hooks::SchemaError, /must be an integer/) do
          Hooks.validate_payload!("tool.call.after", payload)
        end
      end

      it "task.end.error 结构化错误：出现时至少含 code:string" do
        good = JSON.parse(%({"task_id": "t-1", "status": "failed","error": {"code": "timeout", "message": "boom"}}))
        Hooks.validate_payload!("task.end", good).should be_nil
        bad = JSON.parse(%({"task_id": "t-1", "status": "failed", "error": {"message": "no code"}}))
        expect_raises(Hooks::SchemaError, /error\.code/) do
          Hooks.validate_payload!("task.end", bad)
        end
      end

      it "开式哈希含 false/true 合法（as_bool? 对 false 为假，须 raw is_a? 判型）" do
        payload = JSON.parse(%({"entry": {"text": "x", "enabled": false}}))
        Hooks.validate_payload!("memory.remember.before", payload).should be_nil
        payload = JSON.parse(%({"entry": {"text": "x", "enabled": true}}))
        Hooks.validate_payload!("memory.remember.before", payload).should be_nil
      end

      it "gateway.start 空 payload 契约：空对象通过，任何键拒绝" do
        Hooks.validate_payload!("gateway.start", JSON.parse("{}")).should be_nil
        expect_raises(Hooks::SchemaError, /undeclared key/) do
          Hooks.validate_payload!("gateway.start", JSON.parse(%({"why": "boot"})))
        end
      end

      it "非对象 payload 拒绝；开式哈希内超深嵌套拒绝（NDJSON 深度口径）" do
        expect_raises(Hooks::SchemaError, /must be a JSON object/) do
          Hooks.validate_payload!("session.start", JSON.parse("[]"))
        end
        # 在 memory.remember.before 的开式哈希 entry 内嵌 12 层（超过 MAX_DEPTH=8）
        body = String.build do |io|
          io << %({"entry":{"text":"x","meta":)
          12.times { io << %({"child":) }
          io << "1"
          12.times { io << "}" }
          io << "}}"
        end
        payload = JSON.parse(body)
        expect_raises(Hooks::SchemaError, /depth/) do
          Hooks.validate_payload!("memory.remember.before", payload)
        end
      end
    end
  end
end
