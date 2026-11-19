require "openssl"
require "crypto/subtle"
require "base64"
require "json"
require "../../log"

# 企微自建应用回调加解密（M1-WP4，design.md §5.5；渠道笔记 a1/90968/101033）：
# AESKey = Base64Decode(EncodingAESKey + "=")（43→32 字节）；IV = AESKey 前 16 字节；
# PKCS#7 填充至 32 字节倍数；明文布局 random(16B) + msg_len(4B 大端) + msg + receiveid；
# 验签 msg_signature = SHA1(sort(token, timestamp, nonce, encrypt))；
# 校验 receiveid(corpid) 防跨企业混串（§10.1 fail-closed）。
module Sebas
  module Channels
    module Wecom
      class CryptoError < ::Exception; end

      class WecomCrypto
        getter token : String

        BLOCK = 32

        def initialize(@token : String, @encoding_aes_key : String, @corpid : String)
          raise CryptoError.new("encoding_aes_key must be 43 chars") unless @encoding_aes_key.size == 43
          @aes_key = Base64.decode(@encoding_aes_key + "=")
          raise CryptoError.new("decoded aes key must be 32 bytes") unless @aes_key.size == 32
        end

        # 验签：SHA1(字典序排序(token, timestamp, nonce, encrypt))
        def verify_signature(msg_signature : String, timestamp : String, nonce : String, encrypt : String) : Bool
          expected = signature(timestamp, nonce, encrypt)
          ::Crypto::Subtle.constant_time_compare(expected, msg_signature)
        end

        def signature(timestamp : String, nonce : String, encrypt : String) : String
          Digest::SHA1.hexdigest([@token, timestamp, nonce, encrypt].sort.join)
        end

        # 解密 → (msg, receiveid)；receiveid 校验由调用方按 corpid 执行
        def decrypt(encrypt_b64 : String, expected_receiveid : String) : String
          raw = decrypt_raw(encrypt_b64)
          raise CryptoError.new("plaintext too short") if raw.size < 20
          msg_len = (raw[16].to_u32 << 24) | (raw[17].to_u32 << 16) | (raw[18].to_u32 << 8) | raw[19].to_u32
          raise CryptoError.new("msg_len out of range") if 20 + msg_len > raw.size
          msg = String.new(raw[20, msg_len])
          receiveid = String.new(raw[20 + msg_len..])
          if !expected_receiveid.empty? && receiveid != expected_receiveid
            # 防跨企业回调混串（§10.1）
            raise CryptoError.new("receiveid mismatch: got '#{receiveid}' expected '#{expected_receiveid}'")
          end
          msg
        end

        # 加密（回复/测试向量）：random(16B) + msg_len + msg + receiveid → AES-CBC
        def encrypt(msg : String, receiveid : String = "") : String
          plain = String.build do |builder|
            builder << Random::Secure.hex(8) # 16B random
            len = msg.bytesize
            header = Bytes.new(4)
            header[0] = (len >> 24).to_u8
            header[1] = (len >> 16).to_u8
            header[2] = (len >> 8).to_u8
            header[3] = len.to_u8
            builder.write(header) # msg_len 4B 大端
            builder << msg
            builder << receiveid
          end
          cipher = OpenSSL::Cipher.new("aes-256-cbc")
          cipher.encrypt
          cipher.key = @aes_key
          cipher.iv = @aes_key[0, 16]
          padded = pkcs7_pad(plain)
          Base64.strict_encode(cipher.update(padded) + cipher.final)
        end

        private def decrypt_raw(encrypt_b64 : String) : Bytes
          data = Base64.decode(encrypt_b64)
          # AES 块 16 字节（PKCS#7 业务填充至 32 字节倍数是企微明文层的另一约定）
          raise CryptoError.new("ciphertext not block aligned") if data.size % 16 != 0 || data.empty?
          cipher = OpenSSL::Cipher.new("aes-256-cbc")
          cipher.decrypt
          cipher.key = @aes_key
          cipher.iv = @aes_key[0, 16]
          pkcs7_unpad(cipher.update(data) + cipher.final)
        end

        private def pkcs7_pad(data : String) : Bytes
          pad_len = BLOCK - (data.bytesize % BLOCK)
          padded = Bytes.new(data.bytesize + pad_len)
          data.to_slice.copy_to(padded[0, data.bytesize])
          padded.fill(data.bytesize, pad_len) { pad_len.to_u8 }
          padded
        end

        private def pkcs7_unpad(data : Bytes) : Bytes
          pad_len = data.last
          raise CryptoError.new("bad pkcs7 padding") if pad_len.zero? || pad_len > BLOCK || pad_len > data.size
          data[0, data.size - pad_len]
        end
      end
    end
  end
end
