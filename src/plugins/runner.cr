require "process"
require "json"
require "atomic"
require "../log"
require "./manifest"
require "./protocol"
require "./prelude"

# 每动作子进程 runner（M3-WP4，#16；design.md §12.2/§12.3 + 可行性报告 §二）：
# 每次调用合成 prelude+plugin.rb 程序文件 → spawn 裁剪解释器 → stdin 注入
# request → 帧循环（registered / capability_call 应答 / 恰好一个 result）→
# 结构化 CallOutcome。
#
# 隔离与校验边界（本 WP）：
# - 插件崩溃/超时/协议违规只影响该次调用，以结构化错误返回，不炸宿主；
# - watchdog 到点 kill 子进程（真超时拦截，可行性报告：进程内 eval 不可中断，
#   子进程形态成立的前提）；
# - stdout 帧字段闭集、单帧/总量上限、结果唯一性、request_id 匹配全部校验；
# - capability 未在 manifest 声明 → 宿主直接回结构化错误，不调用 driver。
# 资源配额细化（allocf/OS 限制/进程树清理）与 22 hook 注入点归 M3-WP5。
module Sebas
  module Plugins
    # 宿主装配错误（解释器不可执行、路径缺失等）：这是配置错误，应当场
    # 响亮报错而不是伪装成插件失败（fail-fast 与插件崩溃隔离相区分）。
    class RunnerError < ::Exception; end

    # 单次调用结果：ok=true 时 value 为 JSON-like 结果；否则带结构化错误码。
    record CallOutcome,
      ok : Bool,
      value : JSON::Any?,
      error_code : String?,
      error_message : String?,
      duration_ms : Int64,
      diagnostics : String? = nil do
      def self.success(value : JSON::Any?, duration_ms : Int64) : CallOutcome
        new(true, value, nil, nil, duration_ms)
      end

      def self.error(code : String, message : String, duration_ms : Int64,
                     diagnostics : String? = nil) : CallOutcome
        new(false, nil, code, message, duration_ms, diagnostics)
      end
    end

    class Runner
      Log = Sebas::Log.for("plugins.runner")

      # 解释器命令：命令 + 固定前缀参数；合成程序文件路径由 runner 追加。
      # 例：["mruby"] / ["ruby", "spec/plugins/support/stub_interpreter.rb"]
      getter interpreter : Array(String)
      property global_timeout_ms : Int64

      # capability driver 装配点（gateway 接线；(plugin, capability, params)
      # → JSON-like 结果，抛异常即失败）。未装配而插件声明调用 = 装配缺口，
      # 按结构化错误回给插件（不炸进程）。
      setter capability_handler : (LoadedPlugin, String, JSON::Any -> JSON::Any)?
      getter capability_handler : (LoadedPlugin, String, JSON::Any -> JSON::Any)?

      def initialize(@interpreter : Array(String), @global_timeout_ms : Int64 = 10_000i64)
      end

      def call(plugin : LoadedPlugin, request : Protocol::Request) : CallOutcome
        started = Time.instant
        source = begin
          File.read(plugin.entry_file)
        rescue ex : ::Exception
          raise RunnerError.new("plugin entry not readable: #{plugin.entry_file} (#{ex.message})")
        end
        program = Prelude.compose(source)
        program_path = Path[Dir.tempdir] / "sebas-plugin-#{Random::Secure.hex(8)}.rb"
        File.write(program_path, program)
        run_plugin(plugin, request, program_path, started)
      ensure
        File.delete(program_path) if program_path && File.exists?(program_path)
      end

      private def timeout_ms_for(plugin : LoadedPlugin) : Int64
        manifest_timeout = plugin.manifest.timeout_ms
        return @global_timeout_ms unless manifest_timeout
        Math.min(manifest_timeout, @global_timeout_ms)
      end

      private def run_plugin(plugin : LoadedPlugin, request : Protocol::Request,
                             program_path : Path, started : Time::Instant) : CallOutcome
        command = interpreter.first?
        raise RunnerError.new("interpreter command is empty") unless command
        process = Process.new(command, interpreter[1..] + [program_path.to_s],
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe)
      rescue ex : ::Exception
        raise RunnerError.new("failed to spawn plugin interpreter #{interpreter.inspect}: #{ex.message}")
      else
        exchange_frames(process, plugin, request, started)
      end

      # 帧循环主体。所有异常就地转结构化 CallOutcome——插件任何失败模式
      # （崩溃/超时/协议违规/宿主应答异常）都不逃出本次调用。
      # ameba:disable Metrics/CyclomaticComplexity — 三类帧 × 失败模式的状态机，分支即语义
      private def exchange_frames(process : Process, plugin : LoadedPlugin,
                                  request : Protocol::Request, started : Time::Instant) : CallOutcome
        duration = -> { (Time.instant - started).total_milliseconds.to_i64 }
        diagnostics = StderrDrainer.new(process.error)
        diagnostics.drain

        # 请求注入（单行 JSON）。stdin 保持打开：执行期还要写 capability_result。
        process.input << request.to_frame << "\n"
        process.input.flush

        finished = Channel(Nil).new(1) # 带缓冲：watchdog 走 timeout 分支后 send 不阻塞
        timed_out = Atomic(Bool).new(false)
        timeout_ms = timeout_ms_for(plugin)
        spawn(name: "plugin-call-watchdog") do
          select
          when finished.receive
          when timeout(timeout_ms.milliseconds)
            timed_out.set(true)
            process.terminate(graceful: false) rescue nil
          end
        end

        violation : {String, String}? = nil
        registered_seen = false
        result_frame : Protocol::ResultFrame? = nil
        capability_calls = 0
        stdout_total = 0
        begin
          loop do
            line = process.output.gets
            break unless line
            line = line.chomp
            stdout_total += line.bytesize
            if stdout_total > Protocol::MAX_STDOUT_TOTAL
              violation = {"output_overflow", "stdout exceeds #{Protocol::MAX_STDOUT_TOTAL} bytes"}
              break
            end
            frame = begin
              Protocol.parse_frame(line)
            rescue ex : ProtocolError
              violation = {"protocol_violation", ex.message.to_s}
              break
            end
            case frame
            when Protocol::RegisteredFrame
              if registered_seen || result_frame
                violation = {"protocol_violation", "registered frame out of order"}
                break
              end
              registered_seen = true
              undeclared_actions = frame.actions.reject { |action| plugin.manifest.declares_action?(action) }
              undeclared_hooks = frame.hooks.reject { |hook| plugin.manifest.declares_hook?(hook) }
              undeclared = undeclared_actions + undeclared_hooks
              unless undeclared.empty?
                violation = {"undeclared_registration",
                             "registered handlers not declared in manifest: #{undeclared.join(", ")}"}
              end
            when Protocol::CapabilityCallFrame
              capability_calls += 1
              if capability_calls > Protocol::MAX_CAPABILITY_CALLS
                violation = {"capability_call_overflow",
                             "more than #{Protocol::MAX_CAPABILITY_CALLS} capability calls"}
                break
              end
              reply = dispatch_capability(plugin, frame)
              process.input << Protocol.capability_result(frame.call_id, reply.ok,
                reply.value, reply.error_code, reply.error_message) << "\n"
              process.input.flush
            when Protocol::ResultFrame
              if result_frame
                violation = {"duplicate_result", "more than one result frame"}
                break
              end
              unless frame.request_id == request.request_id
                violation = {"request_id_mismatch",
                             "result.request_id #{frame.request_id.inspect} does not match #{request.request_id.inspect}"}
                break
              end
              result_frame = frame
            end
          end
        rescue ::Exception
          # 管道被 watchdog kill / 进程崩溃打断：就地消化，走下方终态判定
        end
        finished.send(nil)
        begin
          status = process.wait
          exit_code = status.exit_code?
        rescue ::Exception
          exit_code = nil
        end
        stderr_tail = diagnostics.tail
        process.input.close rescue nil

        return timed_out_outcome(duration.call, timeout_ms, stderr_tail) if timed_out.get
        return violation_outcome(violation, duration.call, stderr_tail) if violation
        return result_outcome(result_frame, duration.call) if result_frame
        crash_outcome(exit_code, duration.call, stderr_tail)
      ensure
        # 兜底资源回收：正常路径已在主循环后收尾；异常路径就地关闭并 kill
        process.input.close rescue nil
        process.output.close rescue nil
        process.error.close rescue nil
        process.terminate(graceful: false) rescue nil
      end

      private def dispatch_capability(plugin : LoadedPlugin, frame : Protocol::CapabilityCallFrame) : CallOutcome
        # capability 未声明 = 越权：宿主直接拒绝，不调用 driver（§12.2 双重授权）
        unless plugin.manifest.declares_capability?(frame.capability)
          Log.warn { "capability not authorized: plugin=#{plugin.id} capability=#{frame.capability}" }
          return CallOutcome.error("capability_not_authorized",
            "capability '#{frame.capability}' is not declared in manifest", 0)
        end
        handler = @capability_handler
        unless handler
          return CallOutcome.error("capability_driver_missing",
            "no capability driver assembled for '#{frame.capability}'", 0)
        end
        value = handler.call(plugin, frame.capability, frame.params || JSON::Any.new(nil))
        CallOutcome.success(value, 0)
      rescue ex : ::Exception
        Log.error(exception: ex) { "capability dispatch failed: plugin=#{plugin.id} capability=#{frame.capability}" }
        CallOutcome.error("capability_failed", (ex.message || "capability failed")[0, 500], 0)
      end

      private def timed_out_outcome(duration : Int64, timeout_ms : Int64, stderr : String?) : CallOutcome
        Log.warn { "plugin call timed out: plugin killed (timeout_ms=#{timeout_ms})" }
        CallOutcome.error("timeout", "plugin call exceeded #{timeout_ms}ms and was killed",
          duration, stderr)
      end

      private def violation_outcome(violation : {String, String}?, duration : Int64, stderr : String?) : CallOutcome
        code, message = violation
        Log.warn { "plugin protocol violation: #{code} #{message}" }
        CallOutcome.error(code, message, duration, stderr)
      end

      private def result_outcome(frame : Protocol::ResultFrame, duration : Int64) : CallOutcome
        if frame.ok?
          CallOutcome.success(frame.value, duration)
        else
          CallOutcome.error(frame.error_code || "plugin_error", frame.error_message || "", duration)
        end
      end

      private def crash_outcome(exit_code : Int32?, duration : Int64, stderr : String?) : CallOutcome
        if exit_code.nil? || exit_code == 0
          CallOutcome.error("plugin_no_result", "plugin exited without a result frame", duration, stderr)
        else
          CallOutcome.error("plugin_crash", "plugin exited with code #{exit_code}", duration, stderr)
        end
      end

      # stderr 受限诊断：独立 fiber 持续排空管道（防写满阻塞），截断保存。
      private class StderrDrainer
        @buffer = IO::Memory.new
        @done = Channel(Nil).new(1)

        def initialize(@io : IO::FileDescriptor)
        end

        def drain : Nil
          spawn do
            loop do
              line = @io.gets
              break unless line
              if @buffer.bytesize < Protocol::MAX_STDERR
                @buffer << line
                @buffer << "\n"
              end
            end
          rescue ::Exception
            # 进程被 kill 时管道断开：排空结束
          ensure
            @done.send(nil)
          end
        end

        def tail : String?
          @done.receive
          text = @buffer.to_s
          text.empty? ? nil : text[0, Protocol::MAX_STDERR]
        end
      end
    end
  end
end
