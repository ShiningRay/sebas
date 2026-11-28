require "spec"
require "file_utils"
require "../../../src/sebas"

# 热更新四正交件（M1-WP8）：触发→先验后换→Atomic 换引用→组件重应用（§11.2/§11.3）
def reload_tmp_dir(name : String) : Path
  dir = Path[Dir.tempdir, "sebas-reload-spec", "#{name}-#{Random::Secure.hex(4)}"]
  FileUtils.rm_rf(dir)
  Dir.mkdir_p(dir)
  dir
end

def wait_for(seconds : Time::Span = 5.seconds, &condition : -> Bool) : Bool
  deadline = Time.instant + seconds
  until Time.instant > deadline
    return true if condition.call
    sleep 20.milliseconds
  end
  condition.call
end

BASE_YAML = <<-YAML
  channels:
    email:
      accounts:
        - id: acc-a
          platform: h1
          receive: imap-idle
          credentials: { user: u, password: p }
  agents:
    main: { model: fake/chat }
    work: { model: fake/work }
  bindings:
    - { channel: email, account: acc-a, peer: "*", agent: main }
  gateway:
    http: { bind: 127.0.0.1, port: 18790 }
  YAML

module Sebas
  describe "config hot reload (M1-WP8)" do
    it "swaps a valid config atomically and reports port changes as restart-required (§14 M1)" do
      dir = reload_tmp_dir("swap")
      path = dir / "config.yaml"
      File.write(path, BASE_YAML)

      applied : Array(String) = [] of String
      manager = ::Sebas::Platform::Config::ReloadManager.new(path.to_s) do |config|
        applied << config.agents.keys.join(",")
        # 端口类：标 restart（OpenClaw hybrid 语义）；降级通道（M3-WP5 review）
        # 为空——装配面成功
        outcome = config.gateway.http.try(&.port) == 18791 ? ["gateway.http.port changed: restart required"] : [] of String
        ::Sebas::Platform::Config::ApplyOutcome.new(outcome, [] of String)
      end
      result = manager.reload_from_file
      result.accepted.should be_true
      applied.first.should contain("main")
      ::Sebas::Platform::Config::CURRENT.get.agents.has_key?("main").should be_true

      # 运行中改路由 + 换 provider（agent 增删）：不重启生效
      new_yaml = BASE_YAML
        .gsub("port: 18790", "port: 18791")
        .gsub("  main: { model: fake/chat }", "  main: { model: fake/chat }\n  extra: { model: fake/extra }")
      result = manager.reload_from_content(new_yaml)
      result.accepted.should be_true
      result.restart_required.should contain("gateway.http.port changed: restart required")
      ::Sebas::Platform::Config::CURRENT.get.agents.has_key?("extra").should be_true
      applied.last.should contain("extra")
      FileUtils.rm_rf(dir)
    end

    it "keeps the old config when YAML is broken (写坏保旧报警)" do
      dir = reload_tmp_dir("broken")
      path = dir / "config.yaml"
      File.write(path, BASE_YAML)
      manager = ::Sebas::Platform::Config::ReloadManager.new(path.to_s) { |_| ::Sebas::Platform::Config::ApplyOutcome.new([] of String, [] of String) }
      manager.reload_from_file.accepted.should be_true
      before = ::Sebas::Platform::Config::CURRENT.get.agents.keys.join(",")

      broken = BASE_YAML.gsub("  main: { model: fake/chat }", "  main: { model: fake/chat\n")
      result = manager.reload_from_content(broken)
      result.accepted.should be_false
      result.errors.join("\n").should contain("line")                                # 报错含行号
      ::Sebas::Platform::Config::CURRENT.get.agents.keys.join(",").should eq(before) # 保旧运行
      FileUtils.rm_rf(dir)
    end

    it "rejects dangling binding references (校验先验后换)" do
      dir = reload_tmp_dir("dangling")
      path = dir / "config.yaml"
      File.write(path, BASE_YAML)
      manager = ::Sebas::Platform::Config::ReloadManager.new(path.to_s) { |_| ::Sebas::Platform::Config::ApplyOutcome.new([] of String, [] of String) }
      manager.reload_from_file.accepted.should be_true

      dangling = BASE_YAML.gsub("agent: main }", "agent: ghost }")
      result = manager.reload_from_content(dangling)
      result.accepted.should be_false
      result.errors.join("\n").should contain("'ghost' references an undefined agent")
      # 保旧：binding 未被热换（CURRENT.get 的 bindings 仍指向 main）
      ::Sebas::Platform::Config::CURRENT.get.bindings.first.agent.should eq("main")
      FileUtils.rm_rf(dir)
    end

    it "auto-reloads on watched-file changes with debounce (触发主路)" do
      dir = reload_tmp_dir("watch")
      path = dir / "config.yaml"
      File.write(path, BASE_YAML)
      applied = Atomic(Int32).new(0)
      manager = ::Sebas::Platform::Config::ReloadManager.new(path.to_s) { |_| applied.add(1); ::Sebas::Platform::Config::ApplyOutcome.new([] of String, [] of String) }
      manager.reload_from_file
      manager.start_watching(poll_interval: 200.milliseconds)

      # 编辑器原子替换（tmp+rename）→ Created+Deleted+Renamed 三连 → 去抖后一次 reload。
      # 全量套件高负载下调度可能延迟，触发重试三次（每次改写内容版本）。
      target_model = "fake/v2"
      3.times do |attempt|
        target_model = "fake/v2-r#{attempt + 1}"
        tmp = dir / "config.yaml.tmp"
        File.write(tmp, BASE_YAML.gsub("model: fake/chat", "model: #{target_model}"))
        File.rename(tmp, path)
        break if wait_for(15.seconds) { applied.get >= attempt + 2 }
      end
      ::Sebas::Platform::Config::CURRENT.get.agents["main"].model.should eq(target_model)
      manager.stop_watching
      FileUtils.rm_rf(dir)
    end

    it "rejects unknown commands and serves config.reload via IPC" do
      dir = reload_tmp_dir("ipc")
      path = dir / "config.yaml"
      File.write(path, BASE_YAML)
      store = ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
      applied = Atomic(Int32).new(0)
      manager = ::Sebas::Platform::Config::ReloadManager.new(path.to_s) do |_|
        applied.add(1)
        ::Sebas::Platform::Config::ApplyOutcome.new([] of String, [] of String)
      end
      server = ::Sebas::Admin::IPC::Server.new(store, dir, port: 0) do
        result = manager.reload_from_file
        {
          "accepted"         => JSON::Any.new(result.accepted),
          "errors"           => JSON::Any.new(result.errors.map { |e| JSON::Any.new(e) }),
          "restart_required" => JSON::Any.new([] of JSON::Any),
          "degraded"         => JSON::Any.new([] of JSON::Any),
        }
      end
      server.listen
      begin
        client = ::Sebas::Admin::TUI::Client.new(server.discovery_path)
        client.handshake
        reply = client.request("config.reload").should_not be_nil
        reply["ok"].as_bool.should be_true
        reply["payload"]["accepted"].as_bool.should be_true
        applied.get.should eq(1)
        client.close
      ensure
        server.close
        store.close
        FileUtils.rm_rf(dir)
      end
    end
  end
end
