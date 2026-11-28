require "process"
require "json"
require "atomic"
require "../log"
require "../platform/process_tree"
require "./manifest"
require "./protocol"
require "./prelude"
require "./runner_drain"

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

      # capability driver 装配点（gateway 接线；(plugin, capability, params,
      # replay_key) → JSON-like 结果，抛异常即失败）。replay_key 是请求携带的
      # 幂等键（task 重放身份，可空——hook 路径为 nil）；未装配而插件声明
      # 调用 = 装配缺口，按结构化错误回给插件（不炸进程）。
      setter capability_handler : (LoadedPlugin, String, JSON::Any, String? -> JSON::Any)?
      getter capability_handler : (LoadedPlugin, String, JSON::Any, String? -> JSON::Any)?

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
        # 调用级进程身份（M3-WP5 review）：POSIX spawn 后立即把子进程立为
        # 组长——清理路径 kill(-pid) 可达被 init 收养的后代（pgrep -P 已不可
        # 见）；Windows 无需立组，调用级 Job 即进程身份。
        Platform::ProcessTree.track_call_root(process.pid.to_i32)
        {% if flag?(:windows) %}
          # 调用级 Job（M3-WP5 review）：每次调用独立 Job——终止只及本调用
          # 的进程树，不伤并发活动调用。指派/创建失败即终止回收，不进入帧
          # 循环（无隔离的插件进程不受控）。
          memory_mb = limits.try(&.memory_mb)
          handle = begin
            Platform::ProcessTree::JobObject::JobHandle.new(
              Platform::ProcessTree::JobObject.create(memory_mb.try { |mb| mb.to_u64 * 1024 * 1024 }))
          rescue ex
            Platform::ProcessTree.kill_tree(process.pid.to_i32)
            process.terminate(graceful: false) rescue nil
            raise RunnerError.new("job object create failed (pid=#{process.pid}): #{ex.message}")
          end
          unless Platform::ProcessTree::JobObject.assign(handle.job, process.pid.to_u32)
            handle.terminate_and_close_once? # 同步回收路径：句柄尚未共享
            Platform::ProcessTree.kill_tree(process.pid.to_i32)
            process.terminate(graceful: false) rescue nil
            raise RunnerError.new("job object assign failed (pid=#{process.pid}); plugin process recycled")
          end
          # 终态（含 watchdog 超时后的 process.terminate）统一由本 ensure 的
          # JobHandle 收口：恰好一次终止+关闭，双重调用幂等。Job 指派已生效，
          # TerminateJobObject 覆盖全部后代（含脱离 pgrep 视野的）。
          begin
            return exchange_frames(process, plugin, request, started,
              job_terminate: -> { handle.terminate_and_close_once?; true })
          ensure
            handle.terminate_and_close_once? # 终态统一收口：恰好一次终止+关闭
          end
        {% end %}
        exchange_frames(process, plugin, request, started)
      end

      # spawn 命令合成：limits 存在时 POSIX 以 ulimit 包装（-v 虚存 KB /
      # -t CPU 秒），`exec "$0" "$@"` 保持解释器为直接子进程语义；全部
      # ulimit 成功才 exec（M3-WP5 review：`;` 顺序列表不会因前置失败停摆，
      # 放行即资源上限未生效）——失败停启动并留 stderr 诊断（exit 126）。
      # Windows 资源上限由 Job Object 承载，不改命令形状。
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
          ensure_interpreter_spawnable(interpreter[0])
          script = "if " + directives.join(" && ") +
                   "; then exec \"$0\" \"$@\"; else echo 'sebas plugin runner: resource limit setup failed' >&2; exit 126; fi"
          {"/bin/sh", ["-c", script, interpreter[0]] + args}
        {% elsif flag?(:windows) %}
          {interpreter[0], args}
        {% end %}
      end

      {% if flag?(:unix) %}
        # 包装前解释器可启动性检查（M3-WP5 review）：limits 走 /bin/sh 包装
        # 后 Process.new 不再直接触碰解释器，缺解释器报 plugin_crash(exit 127)
        # 而非装配错误——按 PATH 语义解析可执行文件，缺失保持 RunnerError
        # （配置错误类）语义。PATH 中的命令名与绝对路径都覆盖。
        private def ensure_interpreter_spawnable(command : String) : Nil
          if command.includes?('/')
            return if File::Info.executable?(command)
          else
            found = (ENV["PATH"]? || "").split(':').any? do |dir|
              !dir.empty? && File::Info.executable?(File.join(dir, command))
            end
            return if found
          end
          raise RunnerError.new("failed to spawn plugin interpreter #{interpreter.inspect}: executable not found in PATH")
        end
      {% end %}

      # 帧循环主体。所有异常就地转结构化 CallOutcome——插件任何失败模式
      # （崩溃/超时/协议违规/宿主应答异常）都不逃出本次调用。
      # job_terminate（Windows）：调用级 Job 的幂等终止回调——终态先于
      # 排水/等诊断触发（后代持 stderr/stdout 时不阻塞收尾）。
      private def exchange_frames(process : Process, plugin : LoadedPlugin,
                                  request : Protocol::Request, started : Time::Instant,
                                  job_terminate : Proc(Bool)? = nil) : CallOutcome
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
            # 进程树终止（M3-WP5 §12.4 ④）：Windows 走调用级 Job（覆盖全部
            # 后代）；POSIX 先清后代再杀根，防孤儿逃逸；再对直接子进程兜底。
            {% unless flag?(:windows) %}
              Platform::ProcessTree.kill_tree(process.pid.to_i32)
            {% end %}
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
              reply = dispatch_capability(plugin, frame, request)
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
              # 终态提交（M3-WP5 review）：有效 result 通过唯一性 + request_id
              # 校验后即提交并退出帧循环；提交后仍须有界校验后续帧——顶层伪
              # 造 result 后再发 registered 帧 = 乱序违规（WP4 防伪造契约，
              # noisy 夹具锁定）。有界排水兼顾防伪校验与迟到输出不阻塞。
              result_frame = frame
              # 已有违规（如 registered 里的 undeclared_registration）优先——
              # audit 只补「提交后才发现」的乱序/重复，不洗掉前置违规
              violation ||= audit_late_frames(process, late_total: stdout_total)
              break
            end
          end
        rescue ::Exception
          # 管道被 watchdog kill / 进程崩溃打断：就地消化，走下方终态判定
        end
        finished.send(nil)
        # Windows 先行终止调用级 Job（M3-WP5 review）：后代一并终止后再排水
        # /等诊断——stderr 尾等待不因后代持管道而无限阻塞。幂等：ensure 的
        # 收口调用此时返回 false。POSIX 无 Job，kill_tree 承担树终止。
        job_terminate.try(&.call)
        # 终态一律进程树清扫 + 排水（M3-WP5 §12.4 ④）：必须在 wait 之前——
        # 解释器退出后后代被 init 收养，pgrep -P 就再也找不到它们。成功路径
        # 的 kill_tree 对已退出/无后代进程是 no-op；超时/违规路径它承担真正
        # 的树终止（POSIX 另有进程组清扫兜底收养态后代）。排水丢弃迟到输出，
        # 防 wait 前子进程写满管道阻塞。
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

      private def dispatch_capability(plugin : LoadedPlugin, frame : Protocol::CapabilityCallFrame,
                                      request : Protocol::Request) : CallOutcome
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
        # 请求级幂等键（task 重放身份）透传 driver——重放 memo 在生产装配生效
        value = handler.call(plugin, frame.capability, frame.params || JSON::Any.new(nil),
          request.idempotency_key)
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
    end
  end
end
