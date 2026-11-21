require "spec"
require "json"
require "file_utils"
require "../../../src/platform/cli/gateway"
require "../../../src/platform/config/loader"
require "../../support/fake_imap_server"
require "../../support/fake_smtp_server"

def wait_for(seconds : Time::Span = 10.seconds, &condition : -> Bool) : Bool
  deadline = Time.instant + seconds
  until Time.instant > deadline
    return true if condition.call
    sleep 10.milliseconds
  end
  condition.call
end

def gateway_tmp_dir(name : String) : Path
  dir = Path[Dir.tempdir, "sebas-gateway-spec", "#{name}-#{Random::Secure.hex(4)}"]
  FileUtils.rm_rf(dir)
  Dir.mkdir_p(dir)
  dir
end

def gw_test_config : ::Sebas::Platform::Config::Config
  yaml = <<-YAML
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
  ::Sebas::Platform::Config::Loader.from_content(yaml)
end

def gw_smtp_account : ::Sebas::Platform::Config::EmailAccount
  ::Sebas::Platform::Config::EmailAccount.from_yaml(<<-YAML
    id: test-acc
    platform: 127.0.0.1
    receive: imap-idle
    credentials: { user: me@example.com, password: p }
    YAML
  )
end

module Sebas
  describe "gateway M0 gate drill (M0-WP8)" do
    it "runs the full loop: mail in → agent turn → reply out (§14 M0 收发全链路)" do
      imap = FakeImapServer.new
      smtp = FakeSmtpServer.new
      imap.add_mail("1", "alice@example.com", "status", "what is the status?")
      imap.serve
      smtp.serve

      dir = gateway_tmp_dir("e2e")
      config = gw_test_config
      gateway = Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        Providers::FakeProvider.new(agent.model, ["status: all green"])
      end
      # 测试注入：出站适配器指向假 SMTP 端口
      gateway.channels.register(Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))
      gateway.bus.publish(Platform::Bus::InboundMessage.new(
        "evt-e2e-1", "email", "test-acc", "alice@example.com", "what is the status?"
      ))
      gateway.run

      # 以 intent 落 done 为完成判据：发信成功 → 账本/记录落库在 shutdown 前完成（Linux CI 上
      # `smtp.mails.size == 1` 会早于 intent 状态可见，出现假红）
      ok = wait_for { gateway.store.intent_status("evt-e2e-1") == "done" }
      gateway.shutdown
      ok.should be_true
      mail = smtp.mails.first
      mail[:to].should eq("alice@example.com")
      mail[:payload].should contain("status: all green")

      store = Platform::Store::Store.new(dir / "sebas.db")
      store.intent_status("evt-e2e-1").should eq("done")
      transcripts = store.transcripts("agent:main:test-acc:email:alice@example.com")
      transcripts.map(&.role).should eq(["user", "agent"])
      store.close
      imap.close
      smtp.close
    end

    it "does not re-deliver when the same requestId is published twice (§14 M0 发信幂等)" do
      smtp = FakeSmtpServer.new
      smtp.serve
      dir = gateway_tmp_dir("idem")
      config = gw_test_config
      gateway = Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        Providers::FakeProvider.new(agent.model, ["reply A", "reply B"])
      end
      gateway.channels.register(Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))
      gateway.run
      message = Platform::Bus::InboundMessage.new(
        "evt-dup-1", "email", "test-acc", "bob@example.com", "hello"
      )
      gateway.bus.publish(message)
      wait_for { smtp.mails.size == 1 }.should be_true
      gateway.bus.publish(message)     # 渠道重复投递（企微重试/飞书重推口径）
      gateway.process_message(message) # 直重放路径
      gateway.shutdown
      smtp.mails.size.should eq(1) # 幂等：不重发
      smtp.close
    end

    it "replays unfinished intents after restart and sends once (§14 M0 强杀续跑)" do
      smtp = FakeSmtpServer.new
      smtp.serve
      dir = gateway_tmp_dir("recovery")

      # 第一进程：处理到 intent dispatched 即"崩溃"（不落 done）
      store1 = Platform::Store::Store.new(dir / "sebas.db")
      payload = Platform::Bus::InboundMessage.new(
        "evt-crash-1", "email", "test-acc", "carol@example.com", "ping"
      ).to_json
      store1.record_intent("evt-crash-1", "message", payload)
      store1.finish_intent("evt-crash-1", "dispatched")
      store1.close

      # 第二进程：重启恢复 → 重放 → 发信
      config = gw_test_config
      gateway = Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        Providers::FakeProvider.new(agent.model, ["recovered reply"])
      end
      gateway.channels.register(Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))
      gateway.run
      gateway.replay_unfinished
      wait_for { smtp.mails.size == 1 }.should be_true
      gateway.shutdown

      smtp.mails.first[:to].should eq("carol@example.com")
      store2 = Platform::Store::Store.new(dir / "sebas.db")
      store2.intent_status("evt-crash-1").should eq("done")
      store2.close
      smtp.close
    end

    it "drops inbound without matching binding and audits it (M1-WP1 fail-closed)" do
      dir = gateway_tmp_dir("failclosed")
      config = gw_test_config
      gateway = Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        Providers::FakeProvider.new(agent.model, ["never"])
      end
      gateway.process_message(Platform::Bus::InboundMessage.new(
        "evt-nobind-1", "email", "unknown-acc", "x@y.z", "hi"
      ))
      store = Platform::Store::Store.new(Path[dir, "sebas.db"])
      store.intent_status("evt-nobind-1").should eq("failed") # 丢弃并留审计
      store.transcripts("agent:main:unknown-acc:email:x@y.z").should be_empty
      store.close
      gateway.shutdown
    end

    it "schedules two same-session messages in FIFO order through the scheduler chain (调度 WP2)" do
      smtp = FakeSmtpServer.new
      smtp.serve
      dir = gateway_tmp_dir("scheduling")
      config = gw_test_config
      gateway = Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        Providers::FakeProvider.new(agent.model, ["reply A", "reply B"])
      end
      gateway.channels.register(Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))
      gateway.bus.publish(Platform::Bus::InboundMessage.new("evt-sch-1", "email", "test-acc", "carol@example.com", "first"))
      gateway.bus.publish(Platform::Bus::InboundMessage.new("evt-sch-2", "email", "test-acc", "carol@example.com", "second"))
      gateway.run
      ok = wait_for do
        gateway.store.intent_status("evt-sch-1") == "done" &&
          gateway.store.intent_status("evt-sch-2") == "done"
      end
      gateway.shutdown
      ok.should be_true

      store = Platform::Store::Store.new(dir / "sebas.db")
      # 同会话严格保序：先到先答（session-input-scheduling.md §2 queue 语义）
      transcripts = store.transcripts("agent:main:test-acc:email:carol@example.com")
      transcripts.map(&.role).should eq(["user", "agent", "user", "agent"])
      transcripts[0].content.should eq("first")
      transcripts[1].content.should eq("reply A")
      transcripts[2].content.should eq("second")
      transcripts[3].content.should eq("reply B")
      # 批次落库：两批 done、成员 done（持久调度权威）
      done_batches = store.batches_by_status(Sessions::Scheduling::BatchStatus::Done)
      done_batches.size.should eq(2)
      done_batches.each do |batch|
        store.batch_inputs(batch.batch_id).map(&.status).should eq(["done"])
      end
      smtp.mails.size.should eq(2)
      store.close
      smtp.close
    end

    it "drops unroutable inbound before admission without occupying the queue (§4.2 fail-closed)" do
      smtp = FakeSmtpServer.new
      smtp.serve
      dir = gateway_tmp_dir("noadmit")
      config = gw_test_config
      gateway = Platform::CLI::Gateway.new(config, dir) do |agent, _key|
        Providers::FakeProvider.new(agent.model, ["routed reply"])
      end
      gateway.channels.register(Channels::Email::EmailChannelAdapter.new(
        gw_smtp_account, gateway.bus, smtp_host: "127.0.0.1", smtp_port: smtp.port, smtp_tls: "none"
      ))
      # 无 binding 事件在前，可路由事件在后：consumer 单 fiber FIFO——后者被
      # admission 落库即证明前者已处理完毕（替代无证明的 sleep）
      gateway.bus.publish(Platform::Bus::InboundMessage.new(
        "evt-noadmit-1", "email", "unknown-acc", "x@y.z", "hi"
      ))
      gateway.bus.publish(Platform::Bus::InboundMessage.new(
        "evt-noadmit-2", "email", "test-acc", "dave@example.com", "route me"
      ))
      gateway.run
      wait_for { gateway.store.session_input?("evt-noadmit-2") }.should be_true
      gateway.shutdown
      store = Platform::Store::Store.new(Path[dir, "sebas.db"])
      store.session_input?("evt-noadmit-1").should be_false # 未占队列：无 admission 记录
      store.intent_status("evt-noadmit-1").should be_nil    # 也未产生 intent
      smtp.mails.size.should eq(1)                          # 仅可路由事件获得应答
      store.close
      smtp.close
    end

    it "survives a real process kill and resumes from checkpoint (taskkill /F / SIGKILL 口径)" do
      exe =
        {% if flag?(:windows) %}
          Path[File.expand_path("bin/sebas.exe")]
        {% else %}
          Path[File.expand_path("bin/sebas")]
        {% end %}
      unless File.exists?(exe)
        pending! "release binary not built (run `make release` for the full drill)"
      end
      dir = Path["tmp-drill-#{Random::Secure.hex(4)}"]
      FileUtils.rm_rf(dir)
      Dir.mkdir_p(dir)
      at_exit { FileUtils.rm_rf(dir) } rescue nil

      # cwd 相对路径：最小权限环境子进程只对 cwd 可写
      process = Process.new(exe.to_s, ["crashwrite", "crash.db"], chdir: dir.to_s,
        output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
      ready = process.output.gets
      ready = ready.nil? ? "" : ready
      ready.should contain("READY")

      # Windows taskkill /F ≈ kill -9 口径
      {% if flag?(:windows) %}
        kill = Process.run("taskkill", ["/F", "/PID", process.pid.to_s])
        kill.exit_code.should eq(0)
      {% else %}
        Process.signal(Signal::KILL, process.pid)
      {% end %}
      process.wait

      store = ::Sebas::Platform::Store::Store.new(Path[dir, "crash.db"])
      store.intent_status("evt-crash").should eq("pending") # intent 已落库
      task = store.task("turn:evt-crash")
      task.status.should eq("running") # checkpoint 后被强杀
      task.phase.should eq(1)          # 从最近 checkpoint 续跑
      resumed = store.recover!
      resumed.map(&.id).should contain("turn:evt-crash")
      store.close
    end
  end
end
