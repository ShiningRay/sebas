require "json"
require "../../src/channels/telegram/adapter"
require "../../src/platform/store/store"
require "../../src/platform/bus/bus"

# Telegram spec 共享 helper（telegram_spec.cr 与 telegram_store_spec.cr 共用）：
# 可控时钟、临时 store、update 构造、LongPoll 装配。顶层 def（同 email_spec
# 的 wait_for 先例），两个 spec 文件各自 require 本文件。

# 可控时钟：空闲重置判定（≥6 天）按注入的当前时刻计算
class FakeClock
  property now : ::Time

  def initialize(@now : ::Time); end

  def call : ::Time
    @now
  end
end

def build_store(tag : String) : ::Sebas::Platform::Store::Store
  dir = File.join(Dir.tempdir, "sebas-tg-spec-#{tag}-#{Random.new.hex(4)}")
  ::Sebas::Platform::Store::Store.new(dir)
end

def make_update(update_id : Int64, chat_id : String, text : String,
                message_id : Int32 = 1) : ::JSON::Any
  ::JSON.parse({
    update_id: update_id,
    message:   {message_id: message_id, chat: {id: chat_id.to_i64}, date: 1700000000, text: text},
  }.to_json)
end

def make_non_message_update(update_id : Int64) : ::JSON::Any
  ::JSON.parse({update_id: update_id, callback_query: {id: "cb", data: "x"}}.to_json)
end

def build_tg_poll(store, server, account_id, clock)
  api = ::Sebas::Channels::Telegram::BotApi.new(server.token, http: server.client)
  bus = ::Sebas::Platform::Bus::Bus.new(64)
  poll = ::Sebas::Channels::Telegram::LongPoll.new(account_id, api, store, bus, clock: -> { clock.call })
  {poll, bus}
end
