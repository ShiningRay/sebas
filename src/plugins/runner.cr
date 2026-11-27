require "process"
require "json"
require "atomic"
require "../log"
require "../platform/process_tree"
require "./manifest"
require "./protocol"
require "./prelude"

# 每动作子进程 runner（M3-WP4，#16；design.md §12.2/§12.3 + 可行性报告 §二）：
# 每次调用合成 prelude+plugin.rb 程序文件 → spawn 裁剪解释器 → stdin 注入
# request → 帧循环（registered / capability_call 应答 / 恰好一个 result）→
# 结构化 CallOutcome。
#
# 隔离与校验边界（M3-WP4 本 WP）：
# - 插件崩溃/超时/协议违规只影响该次调用，以结构化错误返回，不炸宿主；
# - watchdog 到点 kill 子进程（真超时拦截，可行性报告：进程内 eval 不可中断，
#   子进程形态成立的前提）；
# - stdout 帧字段闭集、单帧/总量上限、结果唯一性、request_id 匹配全部校验；
# - capability 未在 manifest 声明 → 宿主直接回结构化错误，不调用 driver。
#
# M3-WP5（#17）追加（§12.4 ②④）：
# - 进程树清理：watchdog 超时/协议违规/正常终态后 ProcessTree.kill_tree
#   幂等清扫后代进程（POSIX pgrep 树遍历；Windows Job Object）；
# - 迟到输出丢弃：终态帧之后到达的 stdout 一律排水丢弃，不再参与解析
#   （防 duplicate_result 误报，也防管道阻塞）；
# - OS 资源约束：limits（memory_mb/cpu_seconds）——POSIX 以 ulimit 包装
#   spawn（-v 虚存 / -t CPU 秒）；Windows 走 Job Object 内存上限。
module Sebas
  module Plugins
    # 宿主装配错误（解释器不可执行、路径缺失等）：这是配置错误，应当场
    # 响亮报错而不是伪装成插件失败（fail-fast 与插件崩溃隔离相区分）。
    class RunnerError < ::Exception; end

    # OS 级资源约束（§12.4 ②）：nil 即不设限（行为与 WP4 一致）。
    record ResourceLimits,
      memory_mb : Int64?,
      cpu_seconds : Int32? do
      def self.from_config(memory_mb : Int64?, cpu_seconds : Int32?) : ResourceLimits
        limits = new(memory_mb, cpu_seconds)
        if l = limits.memory_mb
          raise RunnerError.new("plugins limits.memory_mb must be positive (got #{l})") unless l > 0
        end
        if s = limits.cpu_seconds
          raise RunnerError.new("plugins limits.cpu_seconds must be positive (got #{s})") unless s > 0
        end
        limits
      end
    end

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
      getter limits : ResourceLimits?

      # capability driver 装配点（gateway 接线；(plugin, capability, params)
      # → JSON-like 结果，抛异常即失败）。未装配而插件声明调用 = 装配缺口，
      # 按结构化错误回给插件（不炸进程）。
      setter capability_handler : (LoadedPlugin, String, JSON::Any -> JSON::Any)?
      getter capability_handler : (LoadedPlugin, String, JSON::Any -> JSON::Any)?

      def initialize(@interpreter : Array(String), @global_timeout_ms : Int64 = 10_000i64,
                     @limits : ResourceLimits? = nil)
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
        command, args = spawn_command(program_path)
        process = Process.new(command, args,
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Pipe)
      rescue ex : RunnerError
        raise ex
      rescue ex : ::Exception
        raise RunnerError.new("failed to spawn plugin interpreter #{interpreter.inspect}: #{ex.message}")
      else
        {% if flag?(:windows) %}
          # Job Object 指派 + 内存上限（§12.4 ②；FFI 细节见
          # platform/process_tree_ffi_windows.cr）
          begin
            Platform::ProcessTree::JobObject.set_memory_limit(limits.memory_mb.not_nil! * 1024 * 1024) if limits && limits.memory_mb
            Platform::ProcessTree::JobObject.assign(process.pid.to_u32)
          rescue ex
            Log.warn { "job object assign failed (pid=#{process.pid}): #{ex.message}" }
          end
        {% end %}
        exchange_frames(process, plugin, request, started)
      end

      # spawn 命令合成：limits 存在时 POSIX 以 ulimit 包装（-v 虚存 KB /
      # -t CPU 秒），`exec "$0" "$@"` 保持解释器为直接子进程语义；Windows
      # 资源上限由 Job Object 承载，不改命令形状。
      private def spawn_command(program_path : Path) : Tuple(String, Array(String))
        args = interpreter[1..] + [program_path.to_s]
        limits = @limits
        return {interpreter[0], args} unless limits
        {% if flag?(:unix) %}
          directives = [] of String
          if mb = limits.memory_mb
            directives << "ulimit -v #{mb * 1024}"
          end
          if sec = limits.cpu_seconds
            directives << "ulimit -t #{sec}"
          end
          return {interpreter[0], args} if directives.empty?
          script = directives.join(" && ") + "; exec \"$0\" \"$@\""
          {"/bin/sh", ["-c", script, interpreter[0]] + args}
        {% elsif flag?(:windows) %}
          {interpreter[0], args}
        {% end %}
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
            # 进程树终止（M3-WP5 §12.4 ④）：先清后代再杀根，防孤儿逃逸；
            # 再对直接子进程兜底 terminate。
            Platform::ProcessTree.kill_tree(process.pid.to_i32)
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
        # 终态一律进程树清扫 + 排水（M3-WP5 §12.4 ④）：必须在 wait 之前——
        # 解释器退出后后代被 init 收养，pgrep -P 就再也找不到它们。成功路径
        # 的 kill_tree 对已退出/无后代进程是 no-op；超时/违规路径它承担真正
        # 的树终止。排水丢弃迟到输出，防 wait 前子进程写满管道阻塞。
        early_kill = timed_out.get || !violation.nil?
        Platform::ProcessTree.kill_tree(process.pid.to_i32)
        drain_late_output(process) if early_kill
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

      # 迟到输出排水：终态帧后读到 EOF 为止，内容按行丢弃（总量计数仍走
      # 上限口径，但不触发违规——丢弃即语义）。
      private def drain_late_output(process : Process) : Nil
        late_bytes = 0
        while line = process.output.gets
          late_bytes += line.bytesize
          if late_bytes > Protocol::MAX_STDOUT_TOTAL
            Log.warn { "late output exceeded #{Protocol::MAX_STDOUT_TOTAL} bytes; rest discarded silently" }
            break
          end
        end
      rescue
        # 管道随子进程退出关闭：EOF/IOError 均为正常结束
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
