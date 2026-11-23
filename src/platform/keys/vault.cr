require "openssl"
require "json"
require "file_utils"
require "../../log"

# 凭据保护（M1-WP7，design.md §10.2）：secrets 不入明文配置。
# 首选 OS keyring（Windows Credential Manager FFI，§15.1 FFI spike 已实测）；
# 存量静态加密：AES-256-GCM secret 文件，主密钥托管于 OS keyring（降级=主密钥文件 0600）。
# 命名空间隔离：key 按 (渠道类型, 账号ID, 名称)。
module Sebas
  module Platform
    module Keys
      Log = Sebas::Log.for("sebas.keys")

      class VaultError < ::Exception; end

      abstract class Vault
        # 命名空间化键：channel/account/name → "channel/account/name"
        def namespaced_key(channel_type : String, account_id : String, name : String) : String
          "#{channel_type}/#{account_id}/#{name}"
        end

        abstract def set(channel_type : String, account_id : String, name : String, secret : String) : Nil
        abstract def get(channel_type : String, account_id : String, name : String) : String?
        abstract def delete(channel_type : String, account_id : String, name : String) : Nil
      end

      # AES-256-GCM 静态加密文件库。格式（JSON per vault file）：
      #   { "v": 1, "entries": { key: { "ct": b64, "iv": b64, "tag": b64 } } }
      class EncryptedFileVault < Vault
        getter file : Path

        @entries = {} of String => Entry

        def initialize(@file : String | Path, @master_key : Bytes)
          raise VaultError.new("master key must be 32 bytes for AES-256") unless @master_key.size == 32
          @entries = load_entries
        end

        # 主密钥来源：OS keyring（Win Credential Manager）→ 降级主密钥文件。
        # 降级文件**先读后写**：重复 open 必须取回同一主密钥（M4.2-WP4 迁移
        # 幂等验收依赖 vault 稳定——每次生成新密钥会让旧密文不可解）。
        def self.open(file : String | Path, keyring : ::Sebas::Platform::Keys::WinCredentialStore?) : EncryptedFileVault
          path = Path[file]
          scope_key = "sebas/master-key/#{path.basename}"
          key = keyring.try(&.get_raw(scope_key)) || resolve_fallback_key(path, keyring, scope_key)
          EncryptedFileVault.new(path, key)
        end

        # 无 keyring 主密钥时的回退解析：master.key 存在读回（先读后写，重复
        # open 取同一密钥）；不存在则 O_EXCL 独占创建（CWE-362 竞态防护：并发
        # 启动的两个 Gateway 只有一个创建成功，失败方重读胜者密钥）。
        # 0600 显式权限（CWE-732：File.write 默认 0666 受 umask 影响会落到
        # 0644 同机其他账户可读——主密钥可读即 vault 全裸）。
        private def self.resolve_fallback_key(path : Path, keyring : ::Sebas::Platform::Keys::WinCredentialStore?, scope_key : String) : Bytes
          key_file = path.parent / "master.key"
          if File.file?(key_file)
            decoded = Base64.decode(File.read(key_file).strip)
            Log.info { "master key restored from fallback file #{key_file}" }
            return decoded
          end
          generated = Random::Secure.random_bytes(32)
          if keyring
            keyring.set_raw(scope_key, generated)
            Log.info { "master key generated into OS keyring (#{scope_key})" }
            return generated
          end
          FileUtils.mkdir_p(path.parent) unless Dir.exists?(path.parent)
          # mkdir 原子锁（CWE-362）：并发启动的 Gateway 只有一个拿到锁生成
          # 密钥，另一方等待 master.key 出现后读回——保证全体取到同一主密钥。
          # 锁目录残留（持有方崩溃）：等待超时后接管重写（损坏状态止损）。
          lock_dir = Path[key_file.to_s + ".lock"]
          locked = false
          begin
            Dir.mkdir(lock_dir)
            locked = true
          rescue File::AlreadyExistsError
            wait_deadline = Time.instant + 10.seconds
            while Time.instant < wait_deadline
              if File.file?(key_file)
                decoded = Base64.decode(File.read(key_file).strip)
                Log.info { "master key created concurrently; waited and read back" }
                return decoded
              end
              sleep 50.milliseconds
            end
            Log.warn { "master key lock stale after timeout; taking over (#{lock_dir})" }
          end
          # 拿锁后复查：存在性检查早于 mkdir，间隙里另一进程可能已完成生成
          # 写入——此时读回并释放锁，不覆盖他人密钥。
          if File.file?(key_file)
            Dir.delete(lock_dir) if locked
            decoded = Base64.decode(File.read(key_file).strip)
            Log.info { "master key created concurrently (re-checked under lock); read back" }
            return decoded
          end
          generated = Random::Secure.random_bytes(32)
          # temp 写完 + rename 原子发布：创建与写完之间的部分内容对并发读方
          # 不可见（temp 名唯一不冲突），防另一 Gateway 读到空/半截密钥。
          # 0600 显式权限（CWE-732）：File.write 默认 0666 受 umask 影响会落
          # 到 0644 同机其他账户可读——主密钥可读即 vault 全裸
          tmp_file = Path[key_file.to_s + ".tmp.#{Process.pid}.#{Random::Secure.hex(4)}"]
          File.write(tmp_file, Base64.strict_encode(generated), perm: 0o600)
          # 持久性顺序（掉电安全）：temp 内容 fsync → rename 原子发布 → 目录
          # 项 fsync。任何同步失败抛 VaultError（宁启动失败不留解不开的密文）。
          begin
            File.open(tmp_file, "r+", &.fsync)
            File.rename(tmp_file, key_file)
            sync_directory_entry(path.parent)
          rescue ex : ::Exception
            # 目录项同步失败 = master.key 目录项未确认持久化——回滚删除该
            # 文件：后续 open 重新生成，不留「文件在而目录项未落盘」的坏状态
            # （掉电丢失目录项 → 新密钥 → 已写密文不可解）。
            File.delete(key_file) if File.file?(key_file)
            raise VaultError.new("master key persistence failed: #{ex.message}")
          end
          Dir.delete(lock_dir) if locked
          Log.warn { "OS keyring unavailable; master key file fallback at #{key_file}" }
          generated
        end

        # 目录项 fsync（POSIX）：rename 后同步父目录，保证掉电后 master.key
        # 目录项已在盘上。Windows 无此语义（NTFS 元数据日志自行保证）。
        private def self.sync_directory_entry(dir : Path) : Nil
          {% if flag?(:windows) %}
            # Windows：跳过（NTFS 日志式文件系统，rename 元数据持久化由系统保证）
          {% else %}
            fd = LibC.open(dir.to_s, LibC::O_RDONLY)
            raise VaultError.new("directory open for fsync failed") if fd < 0
            ret = LibC.fsync(fd)
            LibC.close(fd)
            raise VaultError.new("directory fsync failed") if ret != 0
          {% end %}
        end

        def set(channel_type : String, account_id : String, name : String, secret : String) : Nil
          key = namespaced_key(channel_type, account_id, name)
          @entries[key] = encrypt(secret)
          persist
        end

        def get(channel_type : String, account_id : String, name : String) : String?
          key = namespaced_key(channel_type, account_id, name)
          entry = @entries[key]?
          decrypt(entry) if entry
        end

        def delete(channel_type : String, account_id : String, name : String) : Nil
          @entries.delete(namespaced_key(channel_type, account_id, name))
          persist
        end

        private record Entry, ct : String, iv : String, tag : String

        private def encrypt(plaintext : String) : Entry
          cipher = OpenSSL::Cipher.new("aes-256-gcm")
          cipher.encrypt
          cipher.key = @master_key
          iv = Random::Secure.random_bytes(12)
          cipher.iv = iv
          ct = cipher.update(plaintext) + cipher.final
          Entry.new(Base64.strict_encode(ct), Base64.strict_encode(iv), Base64.strict_encode(cipher.gcm_tag))
        end

        private def decrypt(entry : Entry) : String
          cipher = OpenSSL::Cipher.new("aes-256-gcm")
          cipher.decrypt
          cipher.key = @master_key
          cipher.iv = Base64.decode(entry.iv)
          cipher.gcm_tag = Base64.decode(entry.tag)
          String.new(cipher.update(Base64.decode(entry.ct)) + cipher.final)
        rescue ex : ::Exception
          raise VaultError.new("secret tampered or key mismatch: #{ex.message}") # fail-closed
        end

        private def load_entries : Hash(String, Entry)
          return {} of String => Entry unless File.exists?(@file)
          raw = JSON.parse(File.read(@file))
          raw["entries"].as_h.map { |k, v| {k, Entry.new(v["ct"].as_s, v["iv"].as_s, v["tag"].as_s)} }.to_h
        end

        private def persist : Nil
          FileUtils.mkdir_p(Path[@file].parent) unless Dir.exists?(Path[@file].parent)
          payload = {"v" => 1, "entries" => @entries.map { |k, e| {k, {"ct" => e.ct, "iv" => e.iv, "tag" => e.tag}} }.to_h}
          File.write(@file, payload.to_json)
        end
      end
    end
  end
end
