require "spec"
require "file_utils"
require "http/client"
require "../../src/orchestration/runs_view"
require "../../src/orchestration/engine"
require "../../src/tools/executor"
require "../../src/platform/store/store"
require "../../src/admin/http/server"
require "../../src/admin/ipc/server"
require "../../src/admin/tui/client"
require "../../src/platform/bus/bus"

class NoopTool < ::Sebas::Tools::Tool
  def initialize
    super("noop.hit", "does nothing", ::Sebas::Tools::ReplaySemantics::Safe, ::Sebas::Tools::Risk::Low)
  end

  def run(args : JSON::Any, ctx : ::Sebas::Tools::ToolContext) : ::Sebas::Tools::ToolResult
    ::Sebas::Tools::ToolResult.success("noop")
  end
end

def runs_tmp_store
  dir = Path[Dir.tempdir, "sebas-runs-spec", Random::Secure.hex(4)]
  FileUtils.rm_rf(dir)
  ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
end

def runs_workflow(id : String) : ::Sebas::Orchestration::DSL::Workflow
  ::Sebas::Orchestration::DSL::Workflow.new(id, "t", true,
    ::Sebas::Orchestration::DSL::Trigger.new("webhook", "", "hooks/#{id}"),
    [::Sebas::Orchestration::DSL::Action.new("act", "noop.hit", "{}", "", "", "", 300)], nil)
end

def wait_for(seconds : Time::Span = 5.seconds, &condition : -> Bool) : Bool
  deadline = Time.instant + seconds
  until Time.instant > deadline
    return true if condition.call
    sleep 20.milliseconds
  end
  condition.call
end

module Sebas
  describe "runs view API (M2-WP6)" do
    it "lists workflow runs and replays event order (§14 M2 验收第 4 条 runs 回放审计)" do
      store = runs_tmp_store
      registry = ::Sebas::Tools::Registry.new
      registry.register(NoopTool.new)
      ledger = ::Sebas::Orchestration::Ledger.new(store)
      engine = ::Sebas::Orchestration::Engine.new(store, ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new), ledger: ledger)
      wf = runs_workflow("wf-audit")
      engine.register(wf)
      view = ::Sebas::Orchestration::RunsView.new(store, ledger)

      view.list.should be_empty # 无 run 时空列表

      engine.run_sync(wf, "evt-audit-1")
      runs = view.list
      runs.size.should eq(1)
      JSON.parse(runs.first.to_json)["run_id"].as_s.should eq("run:wf-audit:evt-audit-1")

      detail = view.get("run:wf-audit:evt-audit-1").should_not be_nil
      detail_json = JSON.parse(detail.to_json)
      detail_json["task_status"].as_s.should eq("done")
      detail_json["event_count"].as_i64.should be > 0

      # 事件序回放（审计口径：按 ledger id 单调展示，执行序可重放）
      kinds = detail_json["events"].as_a.map { |e| JSON.parse(e.as_s)["kind"].as_s }
      kinds.should eq(["run.start", "action.start", "action.done", "run.done"])

      # 不存在的 run → nil（HTTP 404 口径）
      view.get("run:missing:x").should be_nil
      store.close
    end

    it "serves runs.list/runs.get over HTTP with auth (面板消费口径)" do
      store = runs_tmp_store
      registry = ::Sebas::Tools::Registry.new
      registry.register(NoopTool.new)
      ledger = ::Sebas::Orchestration::Ledger.new(store)
      engine = ::Sebas::Orchestration::Engine.new(store, ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new), ledger: ledger)
      wf = runs_workflow("wf-http")
      engine.register(wf)
      engine.run_sync(wf, "evt-http-1")
      view = ::Sebas::Orchestration::RunsView.new(store, ledger)

      bus = ::Sebas::Platform::Bus::Bus.new(8)
      server = ::Sebas::Admin::HTTP::Server.new(::Sebas::Channels::Registry.new,
        ::Sebas::Admin::IPC::EventTap.new, "127.0.0.1", 0, "token", "tok", view) do
        {"accepted" => JSON::Any.new(true)} of String => JSON::Any
      end
      server.listen
      begin
        headers = HTTP::Headers{"Authorization" => "Bearer tok"}
        list = HTTP::Client.get("http://127.0.0.1:#{server.port}/api/v1/runs.list", headers: headers)
        list.status_code.should eq(200)
        JSON.parse(list.body)["runs"].as_a.size.should eq(1)

        get = HTTP::Client.get("http://127.0.0.1:#{server.port}/api/v1/runs.get?run_id=run:wf-http:evt-http-1",
          headers: headers)
        get.status_code.should eq(200)
        JSON.parse(get.body)["task_status"].as_s.should eq("done")

        missing = HTTP::Client.get("http://127.0.0.1:#{server.port}/api/v1/runs.get?run_id=run:nope",
          headers: headers)
        missing.status_code.should eq(404)
      ensure
        server.close
        bus.close
      end
    end

    it "serves runs.list/runs.get over IPC" do
      store = runs_tmp_store
      registry = ::Sebas::Tools::Registry.new
      registry.register(NoopTool.new)
      ledger = ::Sebas::Orchestration::Ledger.new(store)
      engine = ::Sebas::Orchestration::Engine.new(store, ::Sebas::Tools::Executor.new(registry, ::Sebas::Channels::Registry.new), ledger: ledger)
      wf = runs_workflow("wf-ipc")
      engine.register(wf)
      engine.run_sync(wf, "evt-ipc-1")
      view = ::Sebas::Orchestration::RunsView.new(store, ledger)

      server = ::Sebas::Admin::IPC::Server.new(store, Path[Dir.tempdir, "sebas-runs-spec", Random::Secure.hex(4)],
        port: 0, runs_view: view) do
        {"accepted" => JSON::Any.new(true)} of String => JSON::Any
      end
      server.listen
      begin
        client = ::Sebas::Admin::TUI::Client.new(server.discovery_path)
        client.handshake
        list = client.request("runs.list").should_not be_nil
        JSON.parse(list.to_json)["payload"]["runs"].as_a.size.should eq(1)

        get = client.request("runs.get", {"run_id" => JSON::Any.new("run:wf-ipc:evt-ipc-1")}).should_not be_nil
        get["payload"]["task_status"].as_s.should eq("done")
        client.close
      ensure
        server.close
        store.close
      end
    end
  end
end
