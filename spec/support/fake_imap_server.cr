require "socket"

# 测试用假 IMAP 服务器（M0-WP4 集成口径）：脚本化应答，压平协议行为。
# 会话剧本：
#   * OK greeting
#   A1 LOGIN → OK
#   A2 SELECT → * N EXISTS / * OK [UIDNEXT n] / * OK [UIDVALIDITY 1] / OK
#   I1 IDLE → + idling；邮件数变化时推 * N EXISTS；DONE → OK
#   A3 UID SEARCH UID x:* → * SEARCH <uid 列表> / OK
#   A4 UID FETCH n → 字面量整封邮件 / OK
#
# IDLE 不再「一进来就报 EXISTS」：只有相对上次 SELECT/EXISTS 通报的邮件数变化才推，
# 否则既有历史每次都当新邮件，测不出「首连跳过历史」的行为。
class FakeImapServer
  getter port : Int32

  # uidvalidity 可变：改值模拟服务端换 UID 命名空间（RFC 3501 §2.3.1.1）
  property uidvalidity : String = "1"

  # 是否在 SELECT 回 UIDNEXT（false 模拟不规范服务端，验证不退回 UID 0 重放历史）
  property? send_uidnext : Bool = true

  # 切到新 UID 命名空间：旧空间的邮件不复存在，UIDNEXT 也从新空间重新计。
  # 只改 uidvalidity 而留着旧邮件，max_uid 会按旧空间算，测不出真实行为。
  def reset_namespace(uidvalidity : String) : Nil
    @mutex.synchronize { @mails.clear }
    self.uidvalidity = uidvalidity
  end

  # 掐断在途会话（模拟网络闪断）：已接受的连接全部关掉，客户端会在下一轮重连
  def drop_connections : Nil
    @mutex.synchronize do
      @sessions.each { |io| io.close rescue nil }
      @sessions.clear
    end
  end

  # 当前在途会话数（断言重连发生了）
  def session_count : Int32
    @mutex.synchronize { @sessions.size }
  end

  def initialize(port : Int32? = nil)
    @server = TCPServer.new("127.0.0.1", port || 0)
    @port = @server.local_address.port
    @seen = [] of String
    @raw = [] of String
    @mutex = Mutex.new
    @mails = {} of String => String
    @reported_size = 0
    @sessions = [] of TCPSocket
  end

  def add_mail(uid : String, from : String, subject : String, body : String) : Nil
    raw = "From: #{from}\r\nTo: me@example.com\r\nSubject: #{subject}\r\n" \
          "Content-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n"
    @mutex.synchronize { @mails[uid] = raw }
  end

  def seen_commands : Array(String)
    @mutex.synchronize { @seen.dup }
  end

  # 原始命令行（含行尾符）：回归断言客户端按 RFC 3501 发 CRLF
  def raw_commands : Array(String)
    @mutex.synchronize { @raw.dup }
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

  private def mail_count : Int32
    @mutex.synchronize { @mails.size }
  end

  private def max_uid : Int64
    @mutex.synchronize { @mails.keys.max_of?(&.to_i64) || 0_i64 }
  end

  private def handle(io : TCPSocket) : Nil
    @mutex.synchronize { @sessions << io }
    io.sync = true
    io.puts "* OK fake imap ready"
    loop do
      line = io.gets(chomp: false)
      break if line.nil?
      @mutex.synchronize { @raw << line }
      line = line.chomp
      @mutex.synchronize { @seen << line }
      break if dispatch(io, line)
    end
    io.close
  rescue ::Exception
    io.close rescue nil
  ensure
    @mutex.synchronize { @sessions.delete(io) }
  end

  # 处理一行命令；返回 true 表示会话结束
  private def dispatch(io : TCPSocket, line : String) : Bool
    words = line.split(" ")
    tag = words[0]
    case words[1]?.try(&.upcase)
    when "LOGIN"
      io.puts "#{tag} OK logged in"
    when "SELECT"
      answer_select(io, tag)
    when "IDLE"
      return !idle(io, tag)
    when "UID"
      handle_uid(io, tag, words[2]?.try(&.upcase) || "", words[3..]? || [] of String)
    when "LOGOUT"
      io.puts "#{tag} OK bye"
      return true
    else
      io.puts "#{tag} OK"
    end
    false
  end

  private def answer_select(io : TCPSocket, tag : String) : Nil
    size = mail_count
    @reported_size = size
    io.puts "* #{size} EXISTS"
    io.puts "* OK [UIDNEXT #{max_uid + 1}] predicted next uid" if send_uidnext?
    io.puts "* OK [UIDVALIDITY #{@uidvalidity}] uids valid"
    io.puts "#{tag} OK [READ-WRITE] selected"
  end

  # IDLE：单 fiber 内以短读超时轮询 DONE 与邮件数变化（不并发读同一 IO）。
  # 邮件数变了才推 EXISTS；否则一直挂着——真实服务端 IDLE 就是这么持久，
  # 提前回 tagged OK 会让客户端在 idle 里继续等下一行直到读超时。
  # 返回 true 表示会话可继续。
  private def idle(io : TCPSocket, tag : String) : Bool
    io.puts "+ idling"
    io.read_timeout = 50.milliseconds
    loop do
      case poll_done(io, tag)
      when :closed then return false
      when :done   then return true
      end
      size = mail_count
      next if size == @reported_size
      @reported_size = size
      io.puts "* #{size} EXISTS"
      io.read_timeout = 30.seconds
    end
  ensure
    io.read_timeout = nil unless io.closed?
  end

  # 轮询客户端是否已发 DONE（读了行就认为收尾，回 tagged OK）
  private def poll_done(io : TCPSocket, tag : String) : Symbol
    line = io.gets
    return :closed if line.nil?
    io.puts "#{tag} OK idle done"
    :done
  rescue IO::TimeoutError
    :waiting
  end

  private def handle_uid(io : TCPSocket, tag : String, sub : String, rest : Array(String)) : Nil
    case sub
    when "SEARCH" then answer_search(io, tag, rest)
    when "FETCH"  then answer_fetch(io, tag, rest)
    else               io.puts "#{tag} OK"
    end
  end

  # UID SEARCH UID <since>:* —— 只回 uid >= since 的项
  private def answer_search(io : TCPSocket, tag : String, rest : Array(String)) : Nil
    spec = rest[1]? || ""
    since = spec.split(":")[0]?.try(&.to_i64?) || 0_i64
    since = 1_i64 if since <= 0
    hits = @mutex.synchronize { @mails.keys.map(&.to_i64).select { |item| item >= since }.sort! }
    io.puts "* SEARCH #{hits.join(' ')}"
    io.puts "#{tag} OK search done"
  end

  private def answer_fetch(io : TCPSocket, tag : String, rest : Array(String)) : Nil
    uid = rest[0]?
    raw = uid.try { |value| @mutex.synchronize { @mails[value]? } } || ""
    io.puts "* #{uid} FETCH (UID #{uid} BODY[] {#{raw.bytesize}}"
    io.puts raw
    io.puts ")"
    io.puts "#{tag} OK fetch done"
  end
end
