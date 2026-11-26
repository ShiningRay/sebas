require "socket"

# 测试用假 SMTP 服务器（M0-WP4 出站验收）：记录会话与 DATA 载荷。
class FakeSmtpServer
  getter port : Int32

  # 已接收邮件：{from, to, payload}
  getter mails : Array(NamedTuple(from: String, to: String, payload: String))

  # 原始命令行（含行尾符）：回归断言客户端按 RFC 5321 发 CRLF
  getter raw_lines : Array(String) = [] of String

  # 原始 DATA 行（含行尾符与终止行 "."）：正文分帧也须 CRLF，
  # 只记命令行测不出正文用裸 LF 的回归
  getter raw_data_lines : Array(String) = [] of String

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    @mails = [] of NamedTuple(from: String, to: String, payload: String)
    @mutex = Mutex.new
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
    io.puts "220 fake smtp ready"
    envelope = {"from" => "", "to" => ""} of String => String
    loop do
      line = io.gets(chomp: false)
      break if line.nil?
      @mutex.synchronize { @raw_lines << line }
      break unless handle_line(io, line.chomp, envelope)
    end
    io.close
  rescue ::Exception
    io.close rescue nil
  end

  # 返回 false 结束会话
  private def handle_line(io : TCPSocket, line : String, envelope : Hash(String, String)) : Bool
    if line.starts_with?("EHLO")
      io.puts "250-fake greets"
      io.puts "250 AUTH PLAIN"
    elsif line.starts_with?("AUTH PLAIN")
      io.puts "235 ok"
    elsif line.starts_with?("MAIL FROM")
      envelope["from"] = line[/MAIL FROM:<([^>]*)>/, 1]? || ""
      io.puts "250 ok"
    elsif line.starts_with?("RCPT TO")
      envelope["to"] = line[/RCPT TO:<([^>]*)>/, 1]? || ""
      io.puts "250 ok"
    elsif line == "DATA"
      read_data(io, envelope["from"], envelope["to"])
    elsif line == "QUIT"
      io.puts "221 bye"
      return false
    else
      io.puts "250 ok"
    end
    true
  end

  private def read_data(io : TCPSocket, from : String, to : String) : Nil
    io.puts "354 go"
    payload = IO::Memory.new
    loop do
      raw = io.gets(chomp: false)
      break if raw.nil?
      @mutex.synchronize { @raw_data_lines << raw }
      data_line = raw.chomp
      break if data_line == "."
      data_line = data_line[1..] if data_line.starts_with?(".") # 逆点填充
      payload << data_line << CRLF
    end
    @mutex.synchronize { @mails << {from: from, to: to, payload: payload.to_s} }
    io.puts "250 queued"
  end

  private CRLF = "\r\n"
end
