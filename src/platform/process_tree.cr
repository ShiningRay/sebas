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
      def self.kill_tree(pid : Int32) : Int32
        count = 0
        descendants(pid).each do |child|
          count += 1 if kill_process(child)
        end
        count += 1 if kill_process(pid)
        count
      end

      # 枚举后代（不含 pid 本身）：POSIX pgrep -P 逐层走（深度/总量双封
      # 顶，进程树失控时不无限枚举）；Windows 返回空——终止路径走 Job
      # Object，无需枚举。
      def self.descendants(pid : Int32) : Array(Int32)
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
            direct_children(cur).each do |child|
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
          JobObject.terminate_by_pid(pid)
        {% else %}
          LibC.kill(pid, LibC::SIGKILL)
          $?.success?
        {% end %}
      rescue
        false
      end

      {% if flag?(:unix) %}
        private def self.direct_children(pid : Int32) : Array(Int32)
          io = IO::Memory.new
          res = Process.run("pgrep", ["-P", pid.to_s],
            input: Process::Redirect::Close,
            output: io,
            error: Process::Redirect::Close)
          return [] of Int32 unless res.success?
          io.to_s.split(/\s+/).compact_map do |line|
            line.to_i?(10)
          end
        rescue
          [] of Int32
        end
      {% end %}
    end
  end
end
