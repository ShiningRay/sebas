# Windows-only FFI（M3-WP5，#17）：Job Object 承载插件子进程树。
#
# 仓库约定：Windows-only FFI 独立文件。runner 在 Spawn 后把解释器进程
# 指派进 job；JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE + 显式 Terminate 双保险，
# ProcessMemoryLimit 承载 §12.4 的 OS 级内存上限（POSIX 走 ulimit 包装）。
#
# 状态：本文件按 Win32 ABI 编写，CI 只保证编译；job 语义的实际行为
# （后代一并终止/内存超限终止）属 Windows 实测项，在 WP5 验收的
# 「未实测」小节登记，不在 macOS/Linux CI 上声称已验证。
{% if flag?(:windows) %}
  module Sebas
    module Platform
      module ProcessTree
        # Win32 常量（minwinbase / winbase）
        private JOB_OBJECT_LIMIT_PROCESS_MEMORY        = 0x00000200_u32
        private JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE     = 0x00002000_u32
        private JobObjectExtendedLimitInformationClass =              9 # JobObjectExtendedLimitInformation
        private PROCESS_SET_QUOTA                      = 0x00000100_u32
        private PROCESS_TERMINATE                      = 0x00000001_u32
        private INVALID_HANDLE_VALUE                   = Pointer(Void).new(-1_i64)

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
            minimum_working_set_size : LibC::SIZE_T
            maximum_working_set_size : LibC::SIZE_T
            active_process_limit : UInt32
            affinitized_processes : Pointer(Void)
            process_priority_class : UInt32
            reserved : StaticArray(UInt32, 4)
          end

          struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
            basic_limit_information : JOBOBJECT_BASIC_LIMIT_INFORMATION
            io_info : IO_COUNTERS
            process_memory_limit : LibC::SIZE_T
            job_memory_limit : LibC::SIZE_T
            peak_process_memory_used : LibC::SIZE_T
            peak_job_memory_used : LibC::SIZE_T
          end

          fun create_job_object_w(lp_job_attributes : Void*, lp_name : Void*) : Void*
          fun set_information_job_object(h_job : Void*, info_class : Int32,
                                         lp_info : JOBOBJECT_EXTENDED_LIMIT_INFORMATION*,
                                         cb_info : UInt32) : Int32
          fun assign_process_to_job_object(h_job : Void*, h_process : Void*) : Int32
          fun terminate_job_object(h_job : Void*, exit_code : UInt32) : Int32
          fun close_handle(h_object : Void*) : Int32
        end

        module JobObject
          Log = Sebas::Log.for("platform.job_object")

          @@mutex = Mutex.new
          @@job : Void*? = nil

          # 每进程一个 job：首个插件进程 Spawn 前惰性创建，进程退出即随
          # KILL_ON_JOB_CLOSE 清理（不显式 CloseHandle——句柄泄漏面最小化）。
          def self.handle : Void*
            @@mutex.synchronize do
              @@job ||= begin
                h = LibJob.create_job_object_w(nil, nil)
                raise "CreateJobObjectW failed" if h.null? || h == INVALID_HANDLE_VALUE
                info = LibJob::JOBOBJECT_EXTENDED_LIMIT_INFORMATION.new
                info.basic_limit_information.limit_flags =
                  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                ok = LibJob.set_information_job_object(h, JobObjectExtendedLimitInformationClass,
                  pointerof(info), sizeof(LibJob::JOBOBJECT_EXTENDED_LIMIT_INFORMATION).to_u32)
                raise "SetInformationJobObject failed" unless ok != 0
                h
              end
            end
          end

          # 设内存上限（字节）：幂等覆盖 limit_flags 的 PROCESS_MEMORY 位。
          def self.set_memory_limit(bytes : UInt64) : Nil
            h = handle
            info = LibJob::JOBOBJECT_EXTENDED_LIMIT_INFORMATION.new
            info.basic_limit_information.limit_flags =
              JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_PROCESS_MEMORY
            info.process_memory_limit = LibC::SIZE_T.new(bytes)
            ok = LibJob.set_information_job_object(h, JobObjectExtendedLimitInformationClass,
              pointerof(info), sizeof(LibJob::JOBOBJECT_EXTENDED_LIMIT_INFORMATION).to_u32)
            Log.warn { "SetInformationJobObject memory limit failed" } unless ok != 0
          end

          # Spawn 后指派：子进程句柄按 pid 打开（需要 PROCESS_SET_QUOTA | TERMINATE；
          # Crystal Process 不暴露句柄）。
          def self.assign(pid : UInt32) : Bool
            opened = open_process(pid)
            return false if opened.nil?
            LibJob.assign_process_to_job_object(handle, opened) != 0
          ensure
            close(opened) if opened
          end

          # 终止 pid（job 内进程随 TerminateJobObject 一并终止；进程已退出
          # 时 OpenProcess 失败返回 false——幂等）。
          def self.terminate_by_pid(pid : UInt32 | Int32) : Bool
            opened = open_process(pid.to_u32)
            return false if opened.nil?
            LibJob.terminate_job_object(handle, 1_u32) != 0
          ensure
            close(opened) if opened
          end

          private def self.open_process(pid : UInt32) : Void*?
            h = LibC.OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, pid)
            (h.null? || h == INVALID_HANDLE_VALUE) ? nil : h
          end

          private def self.close(handle : Void*?) : Nil
            LibJob.close_handle(handle) if handle
          end
        end
      end
    end
  end
{% end %}
