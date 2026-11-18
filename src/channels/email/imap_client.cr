require "socket"
require "openssl"
require "../../log"

# email 渠道（M0-WP4）：最小 IMAP4rev1 客户端 + IDLE（RFC 2177）。
# 范围：LOGIN/SELECT/IDLE/DONE/NOOP/UID SEARCH/FETCH(整封 PEEK)/LOGOUT。
# IDLE 每 ≤29 分钟重发（渠道笔记 c1）：底层 socket read_timeout 兜底，超时返回 nil
# 由调用方重发 IDLE（NAT 掐空闲 TCP 的应用层心跳等价物）。
module Sebas
  module Channels
    module Email
      class ImapError < ::Exception; end

      # 读超时（IDLE 等待窗口耗尽）——不破坏连接，可继续发命令
      class ImapTimeout < ::Exception; end

      record MailSummary, uid : String, from : String, subject : String, body : String

      class ImapClient
        Log = Sebas::Log.for("sebas.channels.email.imap")

        @io : ::IO

        getter last_uidvalidity : String?

        def initialize(host : String, port : Int32, user : String, password : String,
                       tls : Bool = true, connect_timeout : Time::Span = 15.seconds,
                       read_timeout : Time::Span = 30.minutes)
          @user = user
          @password = password
          @tls = tls
          @last_uidvalidity = nil
          @next_tag = 0
          @io = ImapClient.dial(host, port, tls, connect_timeout, read_timeout)
        end

        def self.dial(host : String, port : Int32, tls : Bool,
                      connect_timeout : Time::Span, read_timeout : Time::Span) : ::IO
          socket = TCPSocket.new(host, port, connect_timeout)
          socket.read_timeout = read_timeout
          socket.sync = true
          io = tls ? OpenSSL::SSL::Socket::Client.new(socket, hostname: host).as(::IO) : socket.as(::IO)
          greeting = read_line_io(io)
          raise ImapError.new("imap greeting not OK: #{greeting}") unless greeting.includes?("OK")
          Log.debug { "imap greeting: #{greeting}" }
          io
        rescue ex : ::Exception
          raise ImapError.new("imap connect failed: #{ex.message}")
        end

        def self.read_line_io(io : ::IO) : String
          line = io.gets
          raise ImapError.new("imap connection closed") if line.nil?
          line.chomp
        rescue IO::TimeoutError
          raise ImapTimeout.new("imap read timeout")
        end

        def login : Nil
          resp = run("LOGIN \"#{@user}\" \"#{@password}\"")
          raise ImapError.new("imap login rejected: #{resp["status"]}") unless resp["status"].to_s.includes?("OK")
        end

        def select(mailbox : String = "INBOX") : Nil
          resp = run("SELECT #{mailbox}")
          raise ImapError.new("imap select failed: #{resp["status"]}") unless resp["status"].to_s.includes?("OK")
          @last_uidvalidity = resp["uidvalidity"]?.try(&.to_s)
        end

        # 进入 IDLE：阻塞至出现 EXISTS/EXPUNGE/FLAGS 事件，或 read_timeout 到点。
        # 返回事件行（如 "* 12 EXISTS"）；等待窗口耗尽返回 nil（调用方重发 IDLE）。
        def idle : String?
          tag = "I#{next_tag}"
          @io.puts("#{tag} IDLE")
          @io.flush
          line = read_line
          return unless line.starts_with?("+") # 服务端拒绝 idling
          begin
            loop do
              untagged = read_line
              if untagged.includes?("EXISTS") || untagged.includes?("EXPUNGE") || untagged.includes?("FLAGS")
                return finish_idle(tag, untagged)
              end
            end
          rescue ImapTimeout
            abort_idle(tag)
            return
          end
        end

        private def finish_idle(tag : String, event : String) : String
          @io.puts("DONE")
          @io.flush
          loop do
            line = read_line
            break if line.starts_with?(tag)
          end
          event
        end

        private def abort_idle(tag : String) : Nil
          @io.puts("DONE")
          @io.flush
          loop do
            line = read_line
            break if line.starts_with?(tag)
          end
        rescue ::Exception
          # 超时收尾失败留给上层重连
        end

        # 拉取 uid > since_uid 的整封邮件（BODY.PEEK[] 不动 \Seen）
        def fetch_since(since_uid : String, max_messages : Int32 = 10) : Array(MailSummary)
          resp = run("UID SEARCH UID #{since_uid}:*")
          status = resp["status"].to_s
          raise ImapError.new("imap search failed: #{status}") unless status.includes?("OK")
          uids = resp["uids"].as?(Array(String)) || [] of String
          fetched = [] of MailSummary
          uids.map(&.to_i64).sort!.each do |uid|
            next unless uid > since_uid.to_i64
            break if fetched.size >= max_messages
            mail = fetch_uid(uid.to_s)
            fetched << mail if mail
          end
          fetched.compact
        end

        def fetch_uid(uid : String) : MailSummary?
          resp = run("UID FETCH #{uid} (BODY.PEEK[] UID)")
          raw = resp["body"].to_s
          return if raw.empty?
          parse_message(raw, uid)
        end

        def noop : Nil
          run("NOOP")
        end

        def logout : Nil
          run("LOGOUT")
        rescue ImapError
          # 服务端先行断开不算失败
        end

        def close : Nil
          @io.close
        rescue ::Exception
          nil
        end

        private def run(command : String) : Hash(String, String | Array(String))
          tag = "A#{next_tag}"
          @io.puts("#{tag} #{command}")
          @io.flush
          read_response(tag)
        end

        private def read_response(tag : String) : Hash(String, String | Array(String))
          result = Hash(String, String | Array(String)).new
          untagged = [] of String
          buffer = IO::Memory.new
          loop do
            line = read_line
            if line.starts_with?(tag)
              result["status"] = line.sub(tag, "").strip
              result["untagged"] = untagged.join("\n")
              result["body"] = buffer.to_s
              parse_extras(untagged, result)
              return result
            end
            if literal_size = literal_pending?(line)
              chunk = read_exact(literal_size)
              buffer << chunk
              untagged << line
            else
              untagged << line
            end
          end
        end

        private def parse_extras(untagged : Array(String), result : Hash(String, String | Array(String))) : Nil
          untagged.each do |line|
            if uid_list = line.match(/^\* SEARCH(.*)$/)
              result["uids"] = uid_list[1].split(" ").reject(&.empty?)
            elsif uv = line.match(/UIDVALIDITY (\d+)/)
              result["uidvalidity"] = uv[1]
            end
          end
        end

        private def literal_pending?(line : String) : Int32?
          m = line.match(/\{(\d+)\}\r?$/)
          m.try(&.[1].to_i)
        end

        private def read_exact(size : Int32) : String
          String.build(size) do |builder|
            buffer = Bytes.new(4096)
            remaining = size
            while remaining > 0
              n = @io.read(buffer[0, Math.min(buffer.size, remaining)])
              raise ImapError.new("imap closed inside literal") if n.zero?
              builder.write(buffer[0, n])
              remaining -= n
            end
          end
        rescue IO::TimeoutError
          raise ImapTimeout.new("imap read timeout inside literal")
        end

        private def read_line : String
          ImapClient.read_line_io(@io)
        end

        @next_tag = 0

        private def next_tag : Int32
          @next_tag += 1
          @next_tag
        end

        # ---- 极简 MIME：拆头部/正文，text/plain 直用，multipart 取首个 text/plain ----
        private def parse_message(raw : String, uid : String) : MailSummary
          header_end = raw.index("\r\n\r\n") || raw.index("\n\n") || 0
          header_part = raw[0...header_end]
          body_part = raw[header_end..].lstrip("\r\n")
          headers = Hash(String, String).new
          last_key = ""
          header_part.each_line do |line|
            if m = line.match(/^([A-Za-z0-9-]+):\s*(.*)$/)
              headers[m[1].downcase] = m[2]
              last_key = m[1].downcase
            elsif !last_key.empty? && line.starts_with?(" ")
              headers[last_key] += " #{line.strip}" # 折叠续行
            end
          end
          from = extract_address(headers["from"]? || "")
          subject = headers["subject"]? || ""
          body = extract_body(headers, body_part).rstrip("\r\n")
          MailSummary.new(uid, from, subject, body)
        end

        private def extract_address(header : String) : String
          if m = header.match(/<([^>]+)>/)
            m[1]
          else
            header.strip
          end
        end

        private def extract_body(headers : Hash(String, String), body : String) : String
          content_type = headers["content-type"]? || ""
          encoding = (headers["content-transfer-encoding"]? || "").downcase
          if content_type.includes?("boundary=")
            boundary = content_type[/boundary="?([^";]+)"?/, 1]
            part = first_text_part(body, boundary)
            return decode_body(part, encoding) if part
            return body
          end
          decode_body(body, encoding)
        end

        private def first_text_part(body : String, boundary : String) : String?
          body.split("--#{boundary}").find(&.includes?("text/plain")).try do |part|
            content = part.split("\r\n\r\n", 2)
            content[1]? || content[0]?
          end
        end

        private def decode_body(body : String, encoding : String) : String
          case encoding
          when "base64" then Base64.decode_string(body.gsub(/\s+/m, ""))
          when "quoted-printable"
            body.gsub(/=\r?\n/, "").gsub(/=([0-9A-Fa-f]{2})/) { |_, match| match[1].to_i(16).chr.to_s }
          else
            body
          end
        end
      end
    end
  end
end
