require "socket"
require "openssl"
require "base64"
require "../../log"

# email 渠道（M0-WP4）：最小 SMTP 客户端。
# 465 隐式 TLS / 587 STARTTLS / 25 明文；AUTH PLAIN；禁 25 明文中继出站（§5.4 发送）。
module Sebas
  module Channels
    module Email
      class SmtpError < ::Exception; end

      class SmtpClient
        Log = Sebas::Log.for("sebas.channels.email.smtp")

        @io : ::IO

        def initialize(host : String, port : Int32, user : String, password : String,
                       tls_mode : String = "implicit", connect_timeout : Time::Span = 15.seconds,
                       read_timeout : Time::Span = 60.seconds)
          @user = user
          @password = password
          @io = SmtpClient.dial(host, port, tls_mode, connect_timeout, read_timeout)
        end

        def self.dial(host : String, port : Int32, tls_mode : String,
                      connect_timeout : Time::Span, read_timeout : Time::Span) : ::IO
          socket = TCPSocket.new(host, port, connect_timeout)
          socket.read_timeout = read_timeout
          socket.sync = true
          case tls_mode
          when "implicit"
            io = OpenSSL::SSL::Socket::Client.new(socket, hostname: host).as(::IO)
            expect_reply(read_reply_io(io), "220", "smtp greeting")
            io
          when "starttls"
            io = socket.as(::IO)
            expect_reply(read_reply_io(io), "220", "smtp greeting")
            io.puts("EHLO sebas")
            io.flush
            read_multiline(io, "250")
            io.puts("STARTTLS")
            io.flush
            expect_reply(read_reply_io(io), "220", "starttls")
            OpenSSL::SSL::Socket::Client.new(socket, hostname: host).as(::IO)
          else
            io = socket.as(::IO)
            expect_reply(read_reply_io(io), "220", "smtp greeting")
            io
          end
        rescue ex : SmtpError
          raise ex
        rescue ex : ::Exception
          raise SmtpError.new("smtp connect failed: #{ex.message}")
        end

        # 发送一封邮件；返回服务端 message id（有则回传，无则 nil）
        def send_mail(from : String, to : String, subject : String, body : String) : String?
          ehlo
          auth_plain
          dialog("MAIL FROM:<#{from}>", "250")
          dialog("RCPT TO:<#{to}>", "250")
          @io.puts("DATA")
          @io.flush
          expect(read_reply, "354", "data")
          headers = "From: #{from}\r\nTo: #{to}\r\nSubject: #{escape_header(subject)}\r\n" \
                    "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n" \
                    "Date: #{Time.utc.to_rfc2822}\r\n"
          payload = dot_stuff(headers + "\r\n" + body)
          @io.puts(payload)
          @io.puts(".") # DATA 终止符
          @io.flush
          expect(read_reply, "250", "data end")
          @io.puts("QUIT")
          @io.flush
          nil
        end

        def close : Nil
          @io.close
        rescue ::Exception
          nil
        end

        private def ehlo : Nil
          @io.puts("EHLO sebas")
          @io.flush
          reply = read_reply
          expect(reply, "250", "ehlo")
          SmtpClient.read_multiline(@io, "250")
        end

        private def auth_plain : Nil
          payload = Base64.strict_encode("\u0000#{@user}\u0000#{@password}")
          @io.puts("AUTH PLAIN #{payload}")
          @io.flush
          expect(read_reply, "235", "auth")
        end

        private def dialog(command : String, code : String) : Nil
          @io.puts(command)
          @io.flush
          expect(read_reply, code, command)
        end

        private def read_reply : String
          SmtpClient.read_reply_io(@io)
        end

        def self.read_reply_io(io : ::IO) : String
          line = io.gets
          raise SmtpError.new("smtp connection closed") if line.nil?
          line.chomp
        rescue IO::TimeoutError
          raise SmtpError.new("smtp read timeout")
        end

        def self.read_multiline(io : ::IO, code : String) : Nil
          loop do
            reply = read_reply_io(io)
            break unless reply.starts_with?("#{code}-")
          end
        end

        private def expect(reply : String, code : String, stage : String) : Nil
          SmtpClient.expect_reply(reply, code, stage)
        end

        def self.expect_reply(reply : String, code : String, stage : String) : Nil
          return if reply.starts_with?(code)
          raise SmtpError.new("smtp #{stage} rejected: #{reply}")
        end

        # 头部防注入：剥 CR/LF
        private def escape_header(value : String) : String
          value.gsub(/[\r\n]+/, " ")
        end

        # DATA 段点填充（RFC 5321 §4.5.2）
        private def dot_stuff(payload : String) : String
          payload.split("\r\n").join("\r\n") { |line| line.starts_with?(".") ? ".#{line}" : line }
        end
      end
    end
  end
end
