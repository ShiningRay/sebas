require "spec"
require "json"
require "../support/plugins_spec_helper"

# M3-WP5 runner 隔离升级验收（#17；design.md §12.4 ②④）：
# - 后代进程清理：解释器派生的孙进程随 watchdog/终态清扫一并终止（实测）；
# - 迟到输出丢弃：超时终止后的管道残留不炸宿主、不阻塞 wait；
# - OS 资源约束：ulimit 包装下 CPU 超限进程被杀（实测）。
# 脚本化解释器：ruby -e 忽略 runner 追加的程序文件参数，完全控制子进程
# 行为（帧序列/派生后代/忙循环），不依赖 shim 语义。
module Sebas
  module RunnerWp5Helpers
    extend self

    def script_interpreter(code : String) : Array(String)
      ruby = Process.find_executable("ruby")
      pending "需要 ruby" unless ruby
      [ruby.as(String), "-rjson", "-e", code]
    end

    # 合成最小 LoadedPlugin（runner 只读 entry_file 与 manifest 声明集合）。
    def stub_plugin : ::Sebas::Plugins::LoadedPlugin
      dir = Path[Dir.tempdir, "sebas-wp5-spec-#{Random::Secure.hex(4)}"]
      Dir.mkdir_p(dir)
      File.write(dir / "manifest.json", %({"schema_version":1,"id":"wp5","version":"1.0.0","api_version":"1","actions":["run"]}))
      File.write(dir / "plugin.rb", "")
      manifest = ::Sebas::Plugins::Manifest.parse(File.read(dir / "manifest.json"))
      ::Sebas::Plugins::LoadedPlugin.new(dir, manifest)
    end

    def request : ::Sebas::Plugins::Protocol::Request
      ::Sebas::Plugins::Protocol::Request.new(
        request_id: Random::Secure.hex(6),
        plugin_id: "wp5",
        action: "run",
        context: JSON.parse("{}"),
        payload: JSON.parse("{}"),
        config: JSON.parse("{}"),
        idempotency_key: nil,
      )
    end
  end

  describe "plugin runner WP5（M3-WP5 进程树与资源约束）" do
    it "后代进程清理（实测）：解释器派生孙进程，watchdog 超时后一并终止" do
      # 子进程：派生孙进程（睡 30s），孙 pid 写 stderr 诊断，随后父进程睡 30s 等 watchdog
      code = <<-RUBY # ameba:disable Style/HeredocEscape, Style/HeredocIndent
        $stdout.sync = true
        $stderr.sync = true
        request = $stdin.gets
        grandchild = spawn("sleep", "30")
        $stderr.puts "GRANDCHILD-PID=\#{grandchild}"
        $stdout.puts JSON.generate({"type" => "registered", "actions" => [], "hooks" => []})
        $stdout.puts JSON.generate({"type" => "capability_call", "call_id" => "1",
                                    "capability" => "x", "params" => {}})
        sleep 30
      RUBY
      interp = RunnerWp5Helpers.script_interpreter(code)
      runner = ::Sebas::Plugins::Runner.new(interp, global_timeout_ms: 400_i64)
      outcome = runner.call(RunnerWp5Helpers.stub_plugin, RunnerWp5Helpers.request)
      outcome.ok.should be_false
      outcome.error_code.should eq("timeout")
      # 从 stderr 抓孙 pid，确认已被树终止（轮询 2s）
      diag = outcome.diagnostics.to_s
      pid_line = diag.lines.find(&.starts_with?("GRANDCHILD-PID="))
      pending "无法捕获孙 pid" unless pid_line
      grand = (pid_line.should_not be_nil).split("=").last.to_i
      deadline = Time.instant + 2.seconds
      alive = true
      while Time.instant < deadline
        alive = ::Process.exists?(grand)
        break unless alive
        sleep 50.milliseconds
      end
      alive.should be_false, "watchdog 超时后孙进程应已被 kill_tree 终止"
    end

    it "迟到输出丢弃（实测）：watchdog 超时后的管道残留不阻塞、不炸宿主" do
      # 受控时序（M3-WP5 review）：registered 合法消费后，子进程只写**无换行**
      # 的残段——gets 等不到完整行，协议错误不可能提前结束调用；watchdog
      # 超时杀树后，残段字节留在管道里由排水路径真实吃掉（覆盖超时后排水）
      code = <<-RUBY # ameba:disable Style/HeredocEscape, Style/HeredocIndent
        $stdout.sync = true
        request = $stdin.gets
        $stdout.puts JSON.generate({"type" => "registered", "actions" => [], "hooks" => []})
        $stdout.print "late noise line" # 无换行残段：排水口径字节，永不构成可解析行
        sleep 30
      RUBY
      interp = RunnerWp5Helpers.script_interpreter(code)
      runner = ::Sebas::Plugins::Runner.new(interp, global_timeout_ms: 300_i64)
      started = Time.instant
      outcome = runner.call(RunnerWp5Helpers.stub_plugin, RunnerWp5Helpers.request)
      elapsed = (Time.instant - started).total_milliseconds
      outcome.ok.should be_false
      # 收紧断言（M3-WP5 review）：残段没有换行不可能被判 protocol_violation，
      # 结构化终态必须是 watchdog 超时本身——证明排水不阻塞、宿主不炸
      outcome.error_code.should eq("timeout")
      elapsed.should be < 5_000
    end

    {% if flag?(:unix) %}
      it "OS 资源约束（实测）：CPU 上限下忙循环进程被 ulimit 终止" do
        # 子进程：注册后死循环——ulimit -t 1（CPU 秒）触 SIGKILL/SIGXCPU
        code = <<-RUBY # ameba:disable Style/HeredocEscape, Style/HeredocIndent
          $stdout.sync = true
          request = $stdin.gets
          $stdout.puts JSON.generate({"type" => "registered", "actions" => [], "hooks" => []})
          t = Time.now
          while Time.now - t < 30
            # 忙循环吃满 CPU
          end
        RUBY
        interp = RunnerWp5Helpers.script_interpreter(code)
        limits = ::Sebas::Plugins::ResourceLimits.from_config(memory_mb: nil, cpu_seconds: 1)
        runner = ::Sebas::Plugins::Runner.new(interp, global_timeout_ms: 30_000_i64, limits: limits)
        started = Time.instant
        outcome = runner.call(RunnerWp5Helpers.stub_plugin, RunnerWp5Helpers.request)
        elapsed = (Time.instant - started).total_milliseconds
        outcome.ok.should be_false
        # CPU 上限杀进程后无 result 帧：plugin_crash（exit 非零）或
        # plugin_no_result（EOF 干净退出）；二者都证明配额生效即终止
        {"plugin_crash", "plugin_no_result"}.should contain(outcome.error_code)
        # CPU 上限生效即秒级终止，而不是跑满 30 秒
        elapsed.should be < 15_000
      end
    {% end %}
  end
end
