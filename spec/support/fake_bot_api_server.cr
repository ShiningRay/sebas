require "http"
require "json"

# 测试用假 Telegram Bot API 服务器（M3-WP8）：getUpdates/sendMessage，
# 可编程逐轮响应与请求记录。poll_once 同步一发一收：每次 getUpdates 弹出
# 一个预置响应（Deque 空 → 空数组），spec 据此编排空轮询/消息批次序列。
class FakeBotApiServer
  getter port : Int32
  getter token : String
  getter get_offsets : Array(String?)
  getter sent_messages : Array(NamedTuple(chat_id: String, text: String))

  @updates_queue : Deque(Array(::JSON::Any))
  @errors_queue : Deque(NamedTuple(code: Int32, description: String))
  @mutex = Mutex.new
  @server : ::HTTP::Server

  def initialize(@token : String = "123:testtoken")
    listener = TCPServer.new("127.0.0.1", 0)
    @port = listener.local_address.port
    listener.close
    @updates_queue = Deque(Array(::JSON::Any)).new
    @errors_queue = Deque(NamedTuple(code: Int32, description: String)).new
    @get_offsets = Array(String?).new
    @sent_messages = Array(NamedTuple(chat_id: String, text: String)).new
    @server = ::HTTP::Server.new do |context|
      handle(context)
    end
  end

  # 预置下一轮 getUpdates 返回的 update 数组（一发一收队列）
  def queue_updates(updates : Array(::JSON::Any)) : Nil
    @mutex.synchronize { @updates_queue << updates }
  end

  # 预置下一轮 getUpdates 返回错误（ok=false）
  def queue_error(code : Int32, description : String) : Nil
    @mutex.synchronize { @errors_queue << {code: code, description: description} }
  end

  def serve : Nil
    spawn { @server.listen("127.0.0.1", @port) }
    wait_until_listening
  end

  def close : Nil
    @server.close
  rescue
    nil
  end

  def client : ::HTTP::Client
    ::HTTP::Client.new("127.0.0.1", @port)
  end

  private def wait_until_listening : Nil
    deadline = Time.instant + 5.seconds
    until_listening(deadline)
  end

  private def until_listening(deadline : Time::Instant) : Nil
    TCPSocket.new("127.0.0.1", @port).close
  rescue
    raise "fake bot api server not listening" if Time.instant > deadline
    sleep 5.milliseconds
    until_listening(deadline)
  end

  private def handle(context : ::HTTP::Server::Context) : Nil
    # 每响应即断（Connection: close）：Windows keep-alive 复用连接会被
    # WSARecv 中止——客户端下一请求自动重连，规避平台差异
    context.response.headers["Connection"] = "close"
    path = context.request.path
    unless path.starts_with?("/bot#{@token}/")
      context.response.status_code = 404
      return
    end
    method = path.split('/').last?
    case method
    when "getUpdates"
      offset = context.request.query.try { |query| ::URI::Params.parse(query)["offset"]? }
      @mutex.synchronize { @get_offsets << offset }
      if error = pop_error
        context.response.content_type = "application/json"
        context.response.print({ok: false, error_code: error[:code], description: error[:description]}.to_json)
        return
      end
      updates = pop_updates
      context.response.content_type = "application/json"
      context.response.print({ok: true, result: updates}.to_json)
    when "sendMessage"
      params = ::URI::Params.parse(context.request.body.try(&.gets_to_end) || "")
      @mutex.synchronize { @sent_messages << {chat_id: params["chat_id"]? || "", text: params["text"]? || ""} }
      context.response.content_type = "application/json"
      context.response.print({ok: true, result: {message_id: 4242}}.to_json)
    else
      context.response.status_code = 404
    end
  end

  private def pop_updates : Array(::JSON::Any)
    @mutex.synchronize { @updates_queue.shift? } || [] of ::JSON::Any
  end

  private def pop_error
    @mutex.synchronize { @errors_queue.shift? }
  end

  def recorded_offsets : Array(String?)
    @mutex.synchronize { @get_offsets.dup }
  end

  def messages : Array(NamedTuple(chat_id: String, text: String))
    @mutex.synchronize { @sent_messages.dup }
  end
end
