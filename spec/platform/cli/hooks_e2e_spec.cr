require "spec"
require "file_utils"
require "http/client"
require "../../../src/platform/cli/gateway"
require "../../../src/providers/fake_provider"
require "../../support/gateway_spec_helper"
require "../../support/fake_smtp_server"
require "../../../src/channels/email/adapter"

# 本机 HTTP 代理环境变量会劫持 localhost 回调（http_proxy gem patch）——
# spec 进程内清除（不影响外部 shell）
["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"].each do |key|
  ENV.delete(key)
end
ENV["SEBAS_HTTP_TOKEN"] = "tok-hooks-e2e" # hooks 管理鉴权（进程内自设，不依赖运行命令）
HOOK_TOKEN = "tok-hooks-e2e"

module Sebas
  describe "webhook 会话接入（M4.5-WP5）" do
    it "queue 默认：POST /hooks 202 ACK + 逐事件一 run；同 Idempotency-Key 重试不重复入批" do
      dir = gateway_tmp_dir("hooks-e2e")
      FileUtils.mkdir_p(dir / "workflows")
      File.write(dir / "workflows" / "deploy.yaml", <<-YAML
        id: deploy-hook
        description: webhook 触发部署
        enabled: true
        trigger:
          type: webhook
          source: deploy
        actions:
          - id: remember
            tool: memory.save
            args:
              key: "hook-${trigger.event_id}"
              body: "deployed"
        YAML
      )
      config = ::Sebas::Platform::Config::Loader.from_content(<<-YAML
        gateway:
          http:
            port: 28901
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
          main: { model: fake/chat }
        bindings:
          - { channel: email, account: test-acc, peer: "*", agent: main }
        YAML
      )
      provider = ::Sebas::Providers::FakeProvider.new("fake/chat", ["ok"])
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        provider
      end
      gateway.bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
        "noop-1", "email", "test-acc", "n@example.com", "warm up"
      ))
      gateway.run
      base = "http://127.0.0.1:28901"
      no_auth = HTTP::Client.post("#{base}/hooks/deploy", body: "{}")
      no_auth.status_code.should eq(401)

      # 未知 hook 404（fail-closed）
      unknown = HTTP::Client.post("#{base}/hooks/no-such-hook",
        headers: HTTP::Headers{"Authorization" => "Bearer #{HOOK_TOKEN}"}, body: "{}")
      unknown.status_code.should eq(404)

      # 两次提交（不同 Idempotency-Key）：各 202，逐事件独立 run
      r1 = HTTP::Client.post("#{base}/hooks/deploy", headers: HTTP::Headers{
        "Authorization"   => "Bearer #{HOOK_TOKEN}",
        "Idempotency-Key" => "k1",
      }, body: %({"action": "deploy"}))
      r1.status_code.should eq(202)
      b1 = JSON.parse(r1.body)
      b1["event_id"].as_s.should eq("webhook:deploy:k1")
      b1["batch_id"].as_s.should_not be_empty

      r2 = HTTP::Client.post("#{base}/hooks/deploy", headers: HTTP::Headers{
        "Authorization"   => "Bearer #{HOOK_TOKEN}",
        "Idempotency-Key" => "k2",
      }, body: %({"action": "deploy"}))
      r2.status_code.should eq(202)

      # 同 Idempotency-Key 重试：duplicate 不重复入批（同 event_id）
      retry1 = HTTP::Client.post("#{base}/hooks/deploy", headers: HTTP::Headers{
        "Authorization"   => "Bearer #{HOOK_TOKEN}",
        "Idempotency-Key" => "k1",
      }, body: %({"action": "deploy"}))
      retry1.status_code.should eq(202)
      JSON.parse(retry1.body)["status"].as_s.should eq("duplicate")

      _session = "agent:main:hooks:webhook:deploy"
      ok = wait_for(15.seconds) do
        gateway.store.intent_status("webhook:deploy:k1") == "done" &&
          gateway.store.intent_status("webhook:deploy:k2") == "done"
      end
      gateway.shutdown
      ok.should be_true

      # 逐事件独立 run（queue 默认一事件一 run）
      gateway.store.task("run:deploy-hook:webhook:deploy:k1").kind.should eq("run")
      gateway.store.task("run:deploy-hook:webhook:deploy:k2").kind.should eq("run")
      # hook 会话（同一 hook 复用会话）transcript 有事件（run 落库链）
      gateway.store.intent_status("webhook:deploy:k1").should eq("done")
    end

    it "显式 batch：两事件合成一个 run，payload 记录 batch 与全部 event IDs" do
      dir = gateway_tmp_dir("hooks-batch")
      FileUtils.mkdir_p(dir / "workflows")
      File.write(dir / "workflows" / "events.yaml", <<-YAML
        id: events-hook
        description: 批量事件收集
        enabled: true
        trigger:
          type: webhook
          source: events
        batch:
          batch_mode: debounce
          debounce:
            idle_ms: 200
        actions:
          - id: remember
            tool: memory.save
            args:
              key: "events"
              body: "batched"
        YAML
      )
      config = ::Sebas::Platform::Config::Loader.from_content(<<-YAML
        gateway:
          http:
            port: 28902
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
          main: { model: fake/chat }
        bindings:
          - { channel: email, account: test-acc, peer: "*", agent: main }
        YAML
      )
      provider = ::Sebas::Providers::FakeProvider.new("fake/chat", ["ok"])
      gateway = ::Sebas::Platform::CLI::Gateway.new(config, dir) do |_agent, _key|
        provider
      end
      gateway.run
      base = "http://127.0.0.1:28902"

      r1 = HTTP::Client.post("#{base}/hooks/events", headers: HTTP::Headers{
        "Authorization"   => "Bearer #{HOOK_TOKEN}",
        "Idempotency-Key" => "b1",
      }, body: "{}")
      r2 = HTTP::Client.post("#{base}/hooks/events", headers: HTTP::Headers{
        "Authorization"   => "Bearer #{HOOK_TOKEN}",
        "Idempotency-Key" => "b2",
      }, body: "{}")
      r1.status_code.should eq(202)
      r2.status_code.should eq(202)
      batch_id = JSON.parse(r1.body)["batch_id"].as_s
      batch_id.should eq(JSON.parse(r2.body)["batch_id"].as_s) # 同 hook 同批

      # debounce seal → 合成一个 run：payload 记录 batch_id + 全部 event IDs
      run_id = "run:events-hook:webhook:events:b1"
      ok = wait_for(15.seconds) do
        status = begin
          gateway.store.task(run_id).status
        rescue
          nil
        end
        status == "done" || status == "running"
      end
      gateway.shutdown
      ok.should be_true
      payload = JSON.parse(gateway.store.task_payload(run_id).to_s)
      payload["batch_id"].as_s.should eq(batch_id)
      ids = payload["event_ids"].as_a.map(&.as_s)
      ids.should contain("webhook:events:b1")
      ids.should contain("webhook:events:b2")
    end
  end
end
