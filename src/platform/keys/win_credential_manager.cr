{% if flag?(:windows) %}
  require "../../log"
  require "string/utf16"

  # Windows Credential Manager 原始键值存取（M1-WP7 FFI spike，§15.1/plan E 节风险项——已实测）。
  # advapi32 CredWriteW/CredReadW/CredDeleteW；CRED_TYPE_GENERIC；Persist=LocalMachine。
  module Sebas
    module Platform
      module Keys
        class WinCredentialStore
          Log = Sebas::Log.for("keys.wincred")

          CRED_TYPE_GENERIC          = 1_u32
          CRED_PERSIST_LOCAL_MACHINE = 2_u32

          lib Advapi
            struct FILETIME
              low : UInt32
              high : UInt32
            end

            struct CREDENTIALW
              flags : UInt32
              cred_type : UInt32
              target_name : UInt16*
              comment : UInt16*
              last_written : FILETIME
              blob_size : UInt32
              blob : UInt16*
              persist : UInt32
              attribute_count : UInt32
              attributes : Void*
              target_alias : UInt16*
              user_name : UInt16*
            end

            fun cred_write = CredWriteW(credential : CREDENTIALW*, flags : UInt32) : Int32
            fun cred_read = CredReadW(target_name : UInt16*, cred_type : UInt32, flags : UInt32,
                                      credential : CREDENTIALW**) : Int32
            fun cred_delete = CredDeleteW(target_name : UInt16*, cred_type : UInt32, flags : UInt32) : Int32
            fun cred_free = CredFree(buffer : Void*)
            fun get_last_error = GetLastError : UInt32
          end

          class CredentialError < ::Exception; end

          @prefix : String

          def initialize(prefix : String = "sebas")
            @prefix = prefix
          end

          def set_raw(key : String, value : Bytes) : Nil
            target = to_utf16(target_name(key))
            blob = value
            credential = Advapi::CREDENTIALW.new(
              flags: 0_u32, cred_type: CRED_TYPE_GENERIC,
              target_name: target.to_unsafe, comment: Pointer(UInt16).null,
              last_written: Advapi::FILETIME.new,
              blob_size: blob.size.to_u32, blob: Pointer(UInt16).new(blob.to_unsafe.address),
              persist: CRED_PERSIST_LOCAL_MACHINE,
              attribute_count: 0_u32, attributes: Pointer(Void).null,
              target_alias: Pointer(UInt16).null, user_name: Pointer(UInt16).null
            )
            if Advapi.cred_write(pointerof(credential), 0_u32).zero?
              raise CredentialError.new("CredWriteW failed for #{target_name(key)} (err=#{Win32Error.last})")
            end
          end

          def get_raw(key : String) : Bytes?
            target = to_utf16(target_name(key))
            out_ptr = Pointer(Advapi::CREDENTIALW).null
            read = Advapi.cred_read(target.to_unsafe, CRED_TYPE_GENERIC, 0_u32, pointerof(out_ptr))
            if read.zero?
              err = Win32Error.last
              return if err == 1168 # ERROR_NOT_FOUND
              raise CredentialError.new("CredReadW failed for #{target_name(key)} (err=#{err})")
            end
            cred = out_ptr.value
            size = cred.blob_size
            blob = Bytes.new(size)
            blob.copy_from(Pointer(UInt8).new(cred.blob.address), size) if size.positive?
            Advapi.cred_free(out_ptr.as(Void*))
            blob
          end

          def delete_raw(key : String) : Nil
            target = to_utf16(target_name(key))
            if Advapi.cred_delete(target.to_unsafe, CRED_TYPE_GENERIC, 0_u32).zero?
              err = Win32Error.last
              return if err == 1168 # 已不存在视为幂等删除
              raise CredentialError.new("CredDeleteW failed for #{target_name(key)} (err=#{err})")
            end
          end

          private def target_name(key : String) : String
            "#{@prefix}:#{key}"
          end

          private def to_utf16(s : String) : Array(UInt16)
            # UTF-8 → UTF-16LE + 终止 NUL（stdlib string/utf16）
            units = Array.new(s.to_utf16.size, 0_u16)
            s.to_utf16.each_with_index { |unit, i| units[i] = unit }
            units << 0_u16
            units
          end
        end

        module Win32Error
          def self.last : UInt32
            ::Sebas::Platform::Keys::WinCredentialStore::Advapi.get_last_error
          end
        end
      end
    end
  end
{% else %}
  require "../../log"

  # 非 Windows 平台：OS keyring 后端不可用。
  # 保持与 Windows 实现相同的 API 形状，使 vault 可无分支地探测并降级到主密钥文件。
  module Sebas
    module Platform
      module Keys
        class WinCredentialStore
          class CredentialError < ::Exception; end

          def initialize(prefix : String = "sebas")
            @prefix = prefix
          end

          def set_raw(key : String, value : Bytes) : Nil
            raise CredentialError.new("OS keyring is unavailable on this platform")
          end

          def get_raw(key : String) : Bytes?
            nil
          end

          def delete_raw(key : String) : Nil
          end
        end
      end
    end
  end
{% end %}
