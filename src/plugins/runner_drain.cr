# 迟到输出排水/终态帧审计与 stderr 诊断（自 runner.cr 拆分，#287 review）：
# Runner 单文件体量闸（≤400 行）——排水与终态 I/O 组件独立成文件，
# Runner 的调用接口不变（同类 reopen）。
module Sebas
  module Plugins
    class Runner
      # 迟到输出排水（M3-WP5 review）：固定时间预算 + 字节预算，按实际读入
      # 字节计（不按完整行）；任一超限或 EOF 即返回——无论辅助进程是否关闭
      # stdout，exchange_frames 都能继续 wait。超时/超量记日志（诊断树清理
      # 漏网的后代）。
      private DRAIN_TIMEOUT_MS = 2_000i64
      private DRAIN_CHUNK      =     4096

      # 终态后的有界帧校验：完整行（跨读取块重组，M3-WP5 review——块边界
      # 拆断的 result 帧不再逃过检查）解析为协议帧（registered/duplicate
      # result 等乱序即违规——WP4 防伪造契约）；非协议文本按迟到输出丢弃。
      # 时间与字节双预算；读取本身受剩余预算约束（后代持管道不写时不悬挂）。
      # 超限按迟到输出口径放行（此时违规未知 < 伪报风险）。
      private def audit_late_frames(process : Process, late_total : Int32) : {String, String}?
        deadline = Time.instant + DRAIN_TIMEOUT_MS.milliseconds
        seen_bytes = 0
        pending = ""
        loop do
          if Time.instant >= deadline || seen_bytes > Protocol::MAX_STDOUT_TOTAL
            Log.warn { "late frame audit cut short after #{seen_bytes}B (timeout/overflow)" }
            return # 审计中断：按迟到输出口径放行（伪报风险 < 无终态风险）
          end
          slice = Bytes.new(DRAIN_CHUNK)
          n = bounded_read(process.output, slice, deadline)
          if n.zero? # EOF：无换行结尾的残余也作为最后一行解析
            return audit_scan_line(pending.chomp)
          end
          seen_bytes += n
          pending += String.new(slice[0, n])
          # 只把完整行（换行分隔）交给解析；残段留待下一块拼接
          lines = pending.split("\n")
          pending = lines.last
          lines[0...-1].each do |raw|
            violation = audit_scan_line(raw.chomp)
            return violation if violation
          end
        end
      end

      # 单行终态校验：registered/duplicate result 乱序即违规；非协议文本
      # （调试 print 等）与协议外合法帧按迟到输出口径丢弃。
      private def audit_scan_line(line : String) : {String, String}?
        return if line.empty?
        parsed = begin
          Protocol.parse_frame(line)
        rescue ProtocolError
          return # 非协议文本（调试 print 等）：按迟到输出口径丢弃
        end
        case parsed
        when Protocol::RegisteredFrame
          return {"protocol_violation", "registered frame out of order"}
        when Protocol::ResultFrame
          return {"protocol_violation", "more than one result frame"}
        end
        nil
      end

      private def drain_late_output(process : Process) : Nil
        late_bytes = 0
        deadline = Time.instant + DRAIN_TIMEOUT_MS.milliseconds
        loop do
          if Time.instant >= deadline
            Log.warn { "late output drain timed out after #{DRAIN_TIMEOUT_MS}ms (#{late_bytes}B discarded); a descendant may still hold stdout" }
            return
          end
          slice = Bytes.new(DRAIN_CHUNK)
          n = bounded_read(process.output, slice, deadline)
          return if n.zero? # EOF
          late_bytes += n
          if late_bytes > Protocol::MAX_STDOUT_TOTAL
            Log.warn { "late output exceeded #{Protocol::MAX_STDOUT_TOTAL} bytes; rest discarded silently" }
            return
          end
        end
      rescue
        # 管道随子进程退出关闭：EOF/IOError 均为正常结束
      end

      # 有界读取（M3-WP5 review）：把剩余预算应用到读取本身——后代保持
      # 管道打开但不写数据时 read 会悬挂，读取前的 deadline 检查管不到
      # 等待中。IO::FileDescriptor#read_timeout 触发 IO::TimeoutError，按
      # 预算耗尽口径收尾（返回 0 = EOF 语义）。正常 EOF 与字节上限不变。
      private def bounded_read(io : IO::FileDescriptor, slice : Bytes, deadline : Time::Instant) : Int32
        remaining = deadline - Time.instant
        return 0 if remaining <= Time::Span.zero
        io.read_timeout = remaining
        io.read(slice)
      rescue IO::TimeoutError
        Log.warn { "late output read timed out with budget exhausted; a descendant may hold the pipe" }
        0
      end

      # stderr 受限诊断：独立 fiber 持续排空管道（防写满阻塞），截断保存。
      private class StderrDrainer
        @buffer = IO::Memory.new
        @mutex = Mutex.new
        @done = Channel(Nil).new(1)

        def initialize(@io : IO::FileDescriptor)
        end

        def drain : Nil
          spawn do
            loop do
              line = @io.gets
              break unless line
              @mutex.synchronize do
                if @buffer.bytesize < Protocol::MAX_STDERR
                  @buffer << line
                  @buffer << "\n"
                end
              end
            end
          rescue ::Exception
            # 进程被 kill 时管道断开：排空结束
          ensure
            @done.send(nil)
          end
        end

        # 诊断尾部（有界等待）：drain fiber 等不到 EOF（后代持 stderr）时
        # 不无限阻塞收尾——预算耗尽按已捕获内容返回；fd 随 ensure 关闭后
        # drain fiber 自行终止。
        def tail : String?
          select
          when @done.receive
          when timeout(DRAIN_TIMEOUT_MS.milliseconds)
            Log.warn { "stderr tail wait timed out; a descendant may hold stderr" }
          end
          text = @mutex.synchronize { @buffer.to_s }
          text.empty? ? nil : text[0, Protocol::MAX_STDERR]
        end
      end
    end
  end
end
