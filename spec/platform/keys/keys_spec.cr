require "spec"
require "file_utils"
require "../../../src/platform/keys/vault"
require "../../../src/platform/keys/win_credential_manager"

def tmp_vault_dir(name : String) : Path
  dir = Path[ENV["TEMP"], "sebas-keys-spec", "#{name}-#{Random::Secure.hex(4)}"]
  FileUtils.rm_rf(dir)
  Dir.mkdir_p(dir)
  dir
end

module Sebas
  describe "credentials keyring (M1-WP7)" do
    it "round-trips secrets with AES-256-GCM and detects tampering (命名空间隔离)" do
      dir = tmp_vault_dir("gcm")
      vault = ::Sebas::Platform::Keys::EncryptedFileVault.new(dir / "secrets.bin", Random::Secure.random_bytes(32))
      vault.set("email", "acc-a", "password", "s3cret-a")
      vault.set("email", "acc-b", "password", "s3cret-b")
      vault.get("email", "acc-a", "password").should eq("s3cret-a") # 命名空间隔离：同名不同账号
      vault.get("email", "acc-b", "password").should eq("s3cret-b")

      # 错误主密钥重开 → fail-closed
      reopened = ::Sebas::Platform::Keys::EncryptedFileVault.new(dir / "secrets.bin", Random::Secure.random_bytes(32))
      expect_raises(::Sebas::Platform::Keys::VaultError, /tampered|key mismatch/) do
        reopened.get("email", "acc-a", "password")
      end

      # 篡改密文（改文件）→ 以同一主密钥重开 → fail-closed
      raw = File.read(dir / "secrets.bin")
      File.write(dir / "secrets.bin", raw.sub(%q("ct": "), %q("ct": "XX)))
      expect_raises(::Sebas::Platform::Keys::VaultError) do
        ::Sebas::Platform::Keys::EncryptedFileVault.new(dir / "secrets.bin", Random::Secure.random_bytes(32)).get("email", "acc-a", "password")
      end
      FileUtils.rm_rf(dir)
    end

    it "round-trips with the correct master key across reopen" do
      dir = tmp_vault_dir("reopen")
      key = Random::Secure.random_bytes(32)
      vault = ::Sebas::Platform::Keys::EncryptedFileVault.new(dir / "secrets.bin", key)
      vault.set("wecom", "company-a", "secret", "wecom-secret")
      vault.delete("wecom", "company-a", "nonexistent") # 幂等删除不报错

      reopened = ::Sebas::Platform::Keys::EncryptedFileVault.new(dir / "secrets.bin", key)
      reopened.get("wecom", "company-a", "secret").should eq("wecom-secret")
      reopened.get("wecom", "company-a", "other").should be_nil
      reopened.delete("wecom", "company-a", "secret")
      reopened.get("wecom", "company-a", "secret").should be_nil
      FileUtils.rm_rf(dir)
    end

    it "uses Windows Credential Manager as raw master-key store (FFI spike, §15.1)" do
      store = ::Sebas::Platform::Keys::WinCredentialStore.new("sebas.spec")
      key = Random::Secure.random_bytes(32)
      begin
        store.set_raw("test/master", key)
        read_back = store.get_raw("test/master")
        read_back = Bytes[0] if read_back.nil?
        read_back.should eq(key)
        store.delete_raw("test/master")
        store.get_raw("test/master").should be_nil # 幂等删除
      rescue ex : ::Sebas::Platform::Keys::WinCredentialStore::CredentialError
        fail "Windows Credential Manager FFI spike failed: #{ex.message}"
      end
    end

    it "falls back to a master-key file when the OS keyring is unavailable" do
      dir = tmp_vault_dir("fallback")
      vault = ::Sebas::Platform::Keys::EncryptedFileVault.open(dir / "secrets.bin", nil) # 无 OS keyring → 主密钥文件降级
      vault.set("lark", "feishu-main", "app_secret", "ls-1")
      File.exists?(dir / "master.key").should be_true
      vault.get("lark", "feishu-main", "app_secret").should eq("ls-1")
      FileUtils.rm_rf(dir)
    end
  end
end
