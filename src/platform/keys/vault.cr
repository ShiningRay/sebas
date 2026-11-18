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

        # 主密钥来源：OS keyring（Win Credential Manager）→ 降级主密钥文件
        def self.open(file : String | Path, keyring : ::Sebas::Platform::Keys::WinCredentialStore?) : EncryptedFileVault
          path = Path[file]
          scope_key = "sebas/master-key/#{path.basename}"
          key = keyring.try(&.get_raw(scope_key))
          if key.nil?
            key = Random::Secure.random_bytes(32)
            store = keyring
            if store
              store.set_raw(scope_key, key)
              Log.info { "master key generated into OS keyring (#{scope_key})" }
            else
              # 降级：主密钥文件（0600 口径；Windows 上为用户目录文件权限近似）
              key_file = path.parent / "master.key"
              FileUtils.mkdir_p(path.parent) unless Dir.exists?(path.parent)
              File.write(key_file, Base64.strict_encode(key))
              Log.warn { "OS keyring unavailable; master key file fallback at #{key_file}" }
            end
          end
          EncryptedFileVault.new(path, key)
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
