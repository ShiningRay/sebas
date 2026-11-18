require "socket"

# 测试用假 IMAP 服务器（M0-WP4 集成口径）：脚本化应答，压平协议行为。
# 会话剧本：
#   * OK greeting
#   A1 LOGIN → OK
#   A2 SELECT → * 1 EXISTS / * OK [UIDVALIDITY 1] / OK
#   I1 IDLE → + idling ；随后推 * 2 EXISTS（由 push_exists 触发）；DONE → OK
#   A3 UID SEARCH UID 0:* → * SEARCH 1 2 / OK
#   A4 UID FETCH n → 字面量整封邮件 / OK
class FakeImapServer
  getter port : Int32

  def initialize(port : Int32? = nil)
    @server = TCPServer.new("127.0.0.1", port || 0)
    @port = @server.local_address.port
    @seen = [] of String
    @mutex = Mutex.new
    @mails = {} of String => String
  end

  def add_mail(uid : String, from : String, subject : String, body : String) : Nil
    raw = "From: #{from}\r\nTo: me@example.com\r\nSubject: #{subject}\r\n" \
          "Content-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n"
    @mails[uid] = raw
  end

  def seen_commands : Array(String)
    @mutex.synchronize { @seen.dup }
  end

  def serve : Nil
    spawn do
      loop do
        begin
          io = @server.accept
        rescue ::Exception
          break # 服务器已关闭
        end
        spawn handle(io)
      end
    end
  end

  def close : Nil
    @server.close
  end

  private def handle(io : TCPSocket) : Nil
    io.sync = true
    io.puts "* OK fake imap ready"
    tag = ""
    loop do
      line = io.gets
      break if line.nil?
      line = line.chomp
      @mutex.synchronize { @seen << line }
      words = line.split(" ")
      tag = words[0]
      cmd = words[1]?.try(&.upcase) || ""
      case cmd
      when "LOGIN"
        io.puts "#{tag} OK logged in"
      when "SELECT"
        io.puts "* 1 EXISTS"
        io.puts "* OK [UIDVALIDITY 1] uids valid"
        io.puts "#{tag} OK [READ-WRITE] selected"
      when "IDLE"
        break unless idle(io, tag)
      when "UID"
        handle_uid(io, tag, words[2]?.try(&.upcase) || "", words[3]?)
      when "LOGOUT"
        io.puts "#{tag} OK bye"
        break
      else
        io.puts "#{tag} OK"
      end
    end
    io.close
  rescue ::Exception
    io.close rescue nil
  end

  private def idle(io : TCPSocket, tag : String) : Bool
    io.puts "+ idling"
    io.puts "* 2 EXISTS"
    done = io.gets
    return false if done.nil?
    io.puts "#{tag} OK idle done"
    true
  end

  private def handle_uid(io : TCPSocket, tag : String, sub : String, uid : String?) : Nil
    if sub == "SEARCH"
      io.puts "* SEARCH #{@mails.keys.join(' ')}"
      io.puts "#{tag} OK search done"
    elsif sub == "FETCH" && uid
      raw = @mails[uid]? || ""
      io.puts "* #{uid} FETCH (UID #{uid} BODY[] {#{raw.bytesize}}"
      io.puts raw
      io.puts ")"
      io.puts "#{tag} OK fetch done"
    else
      io.puts "#{tag} OK"
    end
  end
end
