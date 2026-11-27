# Windows-only FFI（M3-WP5，#17）：Job Object 承载插件子进程树。
#
# 仓库约定：Windows-only FFI 独立文件。每次插件调用创建**调用级 Job**——
# 指派本调用的解释器进程，终止时 TerminateJobObject 只及本调用的进程树，
# 不伤并发活动调用；KILL_ON_JOB_CLOSE + 显式 Close 双保险。
# ProcessMemoryLimit（0x100 每进程上限）承载 §12.4 的 OS 级内存约束
# （POSIX 走 ulimit 包装）。
#
# 状态：本文件按 Win32 ABI 编写，CI 只保证编译；job 语义的实际行为
# （后代一并终止/内存超限终止）属 Windows 实测项，在 WP5 验收的
# 「未实测」小节登记，不在 macOS/Linux CI 上声称已验证。
{% if flag?(:windows) %}
  module Sebas
    module Platform
      module ProcessTree
        # Win32 常量（minwinbase / winbase；SDK 口径）
        private JOB_OBJECT_LIMIT_PROCESS_MEMORY        = 0x00000100_u32 # 每进程上限（配 ProcessMemoryLimit；0x200 是 Job 总量）
        private JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE     = 0x00002000_u32
        private JobObjectExtendedLimitInformationClass =              9 # JobObjectExtendedLimitInformation
        private PROCESS_SET_QUOTA                      = 0x00000100_u32
        private PROCESS_TERMINATE                      = 0x00000001_u32
        private INVALID_HANDLE_VALUE                   = Pointer(Void).new(-1_i64)

        lib ::LibC
          # Crystal Windows LibC 缺 TerminateJobObject——补绑真名
          # （Create/SetInformation/AssignProcess/CloseHandle 已在根级 LibC
          # jobapi2.cr / handleapi.cr 声明，直接复用，不再重定义）。
          # 必须写 ::LibC：嵌套 lib（ProcessTree::LibC）不重开根级，
          # 其内无法解析 HANDLE/DWORD/BOOL 与 JobObject 的 LibC.* 引用。
          fun TerminateJobObject(h_job : HANDLE, exit_code : DWORD) : BOOL
        end

        lib LibJob
          struct IO_COUNTERS
            read_operation_count : UInt64
            write_operation_count : UInt64
            other_operation_count : UInt64
            read_transfer_count : UInt64
            write_transfer_count : UInt64
            other_transfer_count : UInt64
          end

          struct JOBOBJECT_BASIC_LIMIT_INFORMATION
            per_process_user_time_limit : Int64
            per_job_user_time_limit : Int64
            limit_flags : UInt32
            minimum_working_set_size : LibC::SizeT
            maximum_working_set_size : LibC::SizeT
            active_process_limit : UInt32
            affinitized_processes : Pointer(Void)
            process_priority_class : UInt32
            scheduling_class : UInt32 # SDK：PriorityClass 后单个 DWORD（reserved[4] 会错位扩展结构偏移）
          end

          struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
            basic_limit_information : JOBOBJECT_BASIC_LIMIT_INFORMATION
            io_info : IO_COUNTERS
            process_memory_limit : LibC::SizeT
            job_memory_limit : LibC::SizeT
            peak_process_memory_used : LibC::SizeT
            peak_job_memory_used : LibC::SizeT
          end

          # （Win32 函数声明全部复用 LibC：CreateJobObjectW/SetInformationJobObject/
          # AssignProcessToJobObject 在 jobapi2.cr，CloseHandle 在 handleapi.cr，
          # TerminateJobObject 由上方 LibC 补绑——fun 绑定名是全局符号级检查，
          # 任何 lib 内再定义同名 fun 即 redefinition 编译失败）
        end

        module JobObject
          Log = Sebas::Log.for("platform.job_object")

          # 调用级 Job 的共享同步所有者（M3-WP5 review）：watchdog fiber 与
          # 主 fiber 都可能触发终止——Atomic(Bool) 保证 terminate_and_close
          # 恰好执行一次；已关闭后的后续调用直接返回（句柄值可能已被系统
          # 复用，双重 close 会误关他者）。
          class JobHandle
            @closed = Atomic(Bool).new(false)

            def initialize(@job : Void*)
            end

            def job : Void*
              @job
            end

            # 终止并关闭；幂等——恰一次执行，其余调用返回 nil（未持有时）。
            # 返回 Bool = 本次调用实际执行了终止。
            def terminate_and_close_once? : Bool
              return false if @closed.swap(true).value
              JobObject.terminate_and_close(@job)
            end
          end

          # 创建调用级 Job：可带每进程内存上限（字节）。失败抛错——调用方
          # （runner）回收刚 spawn 的进程并返回装配错误。
          def self.create(memory_bytes : UInt64?) : Void*
            h = LibC.CreateJobObjectW(nil, nil)
            raise "CreateJobObjectW failed" if h.null? || h == INVALID_HANDLE_VALUE
            info = LibJob::JOBOBJECT_EXTENDED_LIMIT_INFORMATION.new
            flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if memory_bytes
              flags |= JOB_OBJECT_LIMIT_PROCESS_MEMORY
              info.process_memory_limit = LibC::SizeT.new(memory_bytes)
            end
            info.basic_limit_information.limit_flags = flags
            ok = LibC.SetInformationJobObject(h, ::LibC::JOBOBJECTINFOCLASS::ExtendedLimitInformation,
              pointerof(info), sizeof(LibJob::JOBOBJECT_EXTENDED_LIMIT_INFORMATION).to_u32)
            unless ok != 0
              LibC.CloseHandle(h)
              raise "SetInformationJobObject failed"
            end
            h
          end

          # Spawn 后指派：子进程句柄按 pid 打开（需要 PROCESS_SET_QUOTA | TERMINATE；
          # Crystal Process 不暴露句柄）。失败由调用方终止回收。
          def self.assign(job : Void*, pid : UInt32) : Bool
            opened = open_process(pid)
            return false if opened.nil?
            LibC.AssignProcessToJobObject(job, opened) != 0
          ensure
            close(opened) if opened
          end

          # 终止调用级 Job 内全部进程（本调用的进程树，含后代与收养态），
          # 随后关闭句柄。经 JobHandle 调用——直接持裸句柄调用只限
          # create/assign 失败的同步回收路径（句柄尚未共享）。
          def self.terminate_and_close(job : Void*) : Bool
            ok = LibC.TerminateJobObject(job, 1_u32) != 0
            LibC.CloseHandle(job)
            ok
          end

          private def self.open_process(pid : UInt32) : Void*?
            h = LibC.OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, pid)
            (h.null? || h == INVALID_HANDLE_VALUE) ? nil : h
          end

          private def self.close(handle : Void*?) : Nil
            LibC.CloseHandle(handle) if handle
          end
        end
      end
    end
  end
{% end %}
