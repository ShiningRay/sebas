# 后代进程树清理与 OS 级资源约束（M3-WP5，#17；design.md §12.4 ②④）。
#
# 插件在每次调用的子进程里运行；解释器若再派生后代（或脚本逃逸出
# watchdog 窗口），仅 terminate 直接子进程会留下孤儿。本模块按平台：
# - POSIX：pgrep -P 递归枚举后代进程树，逐个 SIGKILL（总量封顶防失控）；
# - Windows：Job Object（FFI 见 process_tree_ffi_windows.cr，独立
#   Windows-only FFI 文件）——子进程 Spawn 即指派进 job，内存上限随
#   job 生效，TerminateJobObject 一并终止 job 内全部后代。
#
# 语义（runner 契约）：watchdog 超时、协议违规、正常终态后都调用
# kill_tree——幂等（进程已退/无后代即 no-op），迟到输出由 runner 侧排水丢弃。
module Sebas
  module Platform
    module ProcessTree
      Log = Sebas::Log.for("platform.process_tree")

      private MAX_NODES = 512

      # 终止 pid 及其全部后代。幂等：进程已退出/无后代时不抛错。
      # 返回实际终止的数量（诊断用）。先杀后代再杀根：缩小父进程被杀后
      # 后代被重新收养导致漏杀的窗口。
      # Windows：调用级 Job 承载树终止（runner 终态路径 terminate_and_close），
      # 此处退化为 terminate 直接子进程兜底（后代由 Job 覆盖）。
      def self.kill_tree(pid : Int32) : Int32
        count = 0
        {% unless flag?(:windows) %}
          kids = descendants(pid)
          if kids.nil?
            Log.warn { "pgrep enumeration failed (pid=#{pid}); killing root only — descendants may survive" }
          else
            kids.each do |child|
              count += 1 if kill_process(child)
            end
          end
        {% end %}
        count += 1 if kill_process(pid)
        count
      end

      # 枚举后代（不含 pid 本身）：POSIX pgrep -P 逐层走（深度/总量双封
      # 顶，进程树失控时不无限枚举）；Windows 返回空——终止路径走调用级
      # Job，无需枚举。
      # pgrep 失败（不可用/非零退出）返回 nil 区分「无后代」与「枚举失败」：
      # kill_tree 收到 nil 记日志并照常杀根（不静默当无后代）。
      def self.descendants(pid : Int32) : Array(Int32)?
        {% if flag?(:windows) %}
          [] of Int32
        {% else %}
          out = [] of Int32
          queue = [pid]
          seen = Set(Int32).new([pid])
          depth = 0
          until queue.empty? || out.size >= MAX_NODES || depth >= MAX_DEPTH
            depth += 1
            cur = queue.shift
            children = direct_children(cur)
            return nil if children.nil? # 枚举失败：调用方显式知晓
            children.each do |child|
              next if seen.includes?(child)
              seen << child
              out << child
              queue << child
            end
          end
          out
        {% end %}
      end

      private MAX_DEPTH = 16

      private def self.kill_process(pid : Int32) : Bool
        {% if flag?(:windows) %}
          LibC.TerminateProcess(LibC.OpenProcess(PROCESS_TERMINATE_WIN, 0, pid.to_u32), 1_u32) != 0
        {% else %}
          LibC.kill(pid, LibC::SIGKILL)
          $?.success?
        {% end %}
      rescue
        false
      end

      {% if flag?(:windows) %}
        private PROCESS_TERMINATE_WIN = 0x00000001_u32
      {% end %}

      {% if flag?(:unix) %}
        # pgrep 可用性与执行失败 → nil（区分「无后代」）；成功但无输出 → 空数组
        private def self.direct_children(pid : Int32) : Array(Int32)?
          io = IO::Memory.new
          res = Process.run("pgrep", ["-P", pid.to_s],
            input: Process::Redirect::Close,
            output: io,
            error: Process::Redirect::Close)
          return nil unless res.success?
          io.to_s.split(/\s+/).compact_map do |line|
            line.to_i?(10)
          end
        rescue
          nil
        end
      {% end %}
    end
  end
end
