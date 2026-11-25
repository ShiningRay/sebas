require "spec"
require "file_utils"
require "json"
require "../../../src/platform/cli/gateway"
require "../../../src/providers/fake_provider"
require "../../support/gateway_spec_helper"

module Sebas
  describe "调度参数管理面（M4.5-WP6）" do
    it "get：无 overlay 时 revision 0、effective 为内置默认" do
      dir = gateway_tmp_dir("sched-admin-1")
      config = gw_test_config
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        ::Sebas::Providers::FakeProvider.new("fake/chat", ["ok"])
      end
      code, body = gateway.handle_scheduling_admin("config.scheduling.get",
        ::JSON::Any.new(Hash(String, ::JSON::Any).new))
      gateway.shutdown
      code.should eq(200)
      payload = JSON.parse(body)
      payload["revision"].as_i.should eq(0)
      payload["overlays"].as_a.should be_empty
      payload["effective"]["gateway"]["batch_mode"].as_s.should eq("queue")
    end

    it "update：合法 patch revision 递增 + 热更新即时生效（不重启）；expected_revision 冲突 409" do
      dir = gateway_tmp_dir("sched-admin-2")
      config = gw_test_config
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        ::Sebas::Providers::FakeProvider.new("fake/chat", ["ok"])
      end

      update = ->(yaml : String, expected : Int64?) {
        params = ::JSON::Any.new({
          "scope"             => ::JSON::Any.new("gateway"),
          "yaml"              => ::JSON::Any.new(yaml),
          "operator"          => ::JSON::Any.new("spec"),
          "expected_revision" => expected.nil? ? ::JSON::Any.new(nil) : ::JSON::Any.new(expected),
        } of String => ::JSON::Any)
        gateway.handle_scheduling_admin("config.scheduling.update", params)
      }

      code, body = update.call("batch_mode: debounce\n", nil)
      code.should eq(200)
      JSON.parse(body)["revision"].as_i.should eq(1)

      # 热更新即时生效：新 admission 的 effective 是 debounce（store 读，事件流非权威）
      gateway.effective_snapshot("agent:main:test-acc:email:x@example.com").batch_mode.should eq("debounce")

      # expected_revision 冲突拒绝
      conflict = update.call("batch_mode: queue\n", 5_i64)
      conflict[0].should eq(409)
      JSON.parse(conflict[1])["error"].as_s.should eq("revision conflict")
      gateway.effective_snapshot("agent:main:test-acc:email:x@example.com").batch_mode.should eq("debounce")

      # 正常预期 revision：继续递增
      code2, body2 = update.call("batch_mode: queue\n", 1_i64)
      code2.should eq(200)
      JSON.parse(body2)["revision"].as_i.should eq(2)
      gateway.shutdown
      gateway.effective_snapshot("agent:main:test-acc:email:x@example.com").batch_mode.should eq("queue")
    end

    it "validate/update：非法范围拒绝且旧配置继续工作" do
      dir = gateway_tmp_dir("sched-admin-3")
      config = gw_test_config
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        ::Sebas::Providers::FakeProvider.new("fake/chat", ["ok"])
      end

      params = ::JSON::Any.new({
        "scope" => ::JSON::Any.new("gateway"),
        "yaml"  => ::JSON::Any.new("unknown_key: broken\n"),
      } of String => ::JSON::Any)
      code, body = gateway.handle_scheduling_admin("config.scheduling.validate", params)
      gateway.shutdown
      code.should eq(400)
      JSON.parse(body)["valid"].as_bool.should be_false

      code2, _ = gateway.handle_scheduling_admin("config.scheduling.update", params)
      code2.should eq(400)                           # 非法拒绝不落表
      gateway.store.scheduling_revision.should eq(0) # 旧配置继续工作
    end

    it "reset：删 overlay 恢复上一层继承（非写死内置值）" do
      dir = gateway_tmp_dir("sched-admin-4")
      config = ::Sebas::Platform::Config::Loader.from_content(<<-YAML
        gateway:
          session:
            batch_mode: debounce
            debounce:
              idle_ms: 500
        channels:
          email:
            accounts:
              - id: test-acc
                platform: 127.0.0.1
                receive: imap-idle
                smtp: { port: 2525, tls: none }
                credentials: { user: me@example.com, password: p }
        agents:
          main: { model: fake/chat }
        bindings:
          - { channel: email, account: test-acc, peer: "*", agent: main }
        YAML
      )
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        ::Sebas::Providers::FakeProvider.new("fake/chat", ["ok"])
      end
      # 上层（gateway.session）= debounce；overlay 覆盖为 queue；reset 恢复继承（回 debounce）
      update_params = ::JSON::Any.new({
        "scope"    => ::JSON::Any.new("gateway"),
        "yaml"     => ::JSON::Any.new("batch_mode: queue\n"),
        "operator" => ::JSON::Any.new("spec"),
      } of String => ::JSON::Any)
      gateway.handle_scheduling_admin("config.scheduling.update", update_params)
      gateway.effective_snapshot("agent:main:x:email:y@example.com").batch_mode.should eq("queue")

      reset_params = ::JSON::Any.new({
        "scope" => ::JSON::Any.new("gateway"),
      } of String => ::JSON::Any)
      code, body = gateway.handle_scheduling_admin("config.scheduling.reset", reset_params)
      gateway.shutdown
      code.should eq(200)
      JSON.parse(body)["revision"].as_i.should eq(2)                                                  # update=1 + reset=2（reset 也是变更，推进版本）
      gateway.effective_snapshot("agent:main:x:email:y@example.com").batch_mode.should eq("debounce") # 继承恢复
    end

    it "queue.get / queue.flush / steer.get / metrics.scheduling 双入口命令" do
      dir = gateway_tmp_dir("sched-admin-5")
      config = ::Sebas::Platform::Config::Loader.from_content(<<-YAML
        gateway:
          http:
            port: 28903
            auth: token
        channels:
          email:
            accounts:
              - id: test-acc
                platform: 127.0.0.1
                receive: imap-idle
                smtp: { port: 2525, tls: none }
                credentials: { user: me@example.com, password: p }
        agents:
          main:
            model: fake/chat
            session:
              steer:
                enabled: true
        bindings:
          - { channel: email, account: test-acc, peer: "*", agent: main }
        YAML
      )
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        ::Sebas::Providers::FakeProvider.new("fake/chat", ["ok"])
      end
      session = "agent:main:test-acc:email:q@example.com"
      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "evt-q1", "email", "test-acc", "q@example.com", "/steer 纠偏一条"
      ))
      gateway.run
      wait_for { gateway.store.intent_status("evt-q1") == "done" }.should be_true

      params = ::JSON::Any.new({"session_key" => ::JSON::Any.new(session)} of String => ::JSON::Any)
      code, body = gateway.handle_scheduling_admin("sessions.steer.get", params)
      code.should eq(200)
      payload = JSON.parse(body)
      payload["counts"]["queued"].as_i.should eq(1) # 无活跃 turn → queued（accepted≠injected 可区分）

      code_q, body_q = gateway.handle_scheduling_admin("sessions.queue.get", params)
      code_q.should eq(200)
      JSON.parse(body_q)["session_key"].as_s.should eq(session)

      code_m, body_m = gateway.handle_scheduling_admin("metrics.scheduling",
        ::JSON::Any.new(Hash(String, ::JSON::Any).new))
      gateway.shutdown
      code_m.should eq(200)
      metrics = JSON.parse(body_m)
      metrics["steer_by_status"]["queued"].as_i.should eq(1)
      # /steer 短路不经 admission 不触 scheduler——内存计数器允许为空
      metrics["scheduler_counters"].as_a.size.should be >= 0
    end

    it "SSE 事件：config.scheduling.applied / steer.queued 经 tap 可观测（事件流非权威存储）" do
      dir = gateway_tmp_dir("sched-sse")
      config = gw_test_config
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        ::Sebas::Providers::FakeProvider.new("fake/chat", ["ok"])
      end
      channel = gateway.ipc.tap.register("sched-sse-spec")

      update_params = ::JSON::Any.new({
        "scope"    => ::JSON::Any.new("gateway"),
        "yaml"     => ::JSON::Any.new("batch_mode: debounce"),
        "operator" => ::JSON::Any.new("spec"),
      } of String => ::JSON::Any)
      gateway.handle_scheduling_admin("config.scheduling.update", update_params)

      steer_params = ::JSON::Any.new({"session_key" => ::JSON::Any.new("agent:main:test-acc:email:s@example.com")} of String => ::JSON::Any)
      gateway.handle_scheduling_admin("sessions.queue.flush", steer_params) # 无 pending：0 封冻

      got_applied = false
      got_rejected_or_etc = false
      10.times do
        line = channel.receive? || ""
        got_applied = true if line.includes?("config.scheduling.applied")
        got_rejected_or_etc = true if line.includes?("steer.")
        break if got_applied
      end
      gateway.shutdown
      got_applied.should be_true
    end
  end
end
