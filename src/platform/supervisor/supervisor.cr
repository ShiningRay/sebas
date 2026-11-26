require "digest/sha256"
require "../../log"
require "../../channels/base"
require "../../channels/registry"
require "../bus/bus"

# 账号监督体（M1-WP2）：fiber-per-account 生命周期监督（design.md §5.1）。
# 职责：健康观测与上报（AccountEvent 入总线）、重复凭据 park（不崩溃）、
# 断线退避由适配器自持（email 5s；autobot 无限重连惯用法）。
module Sebas
  module Platform
    module Supervisor
      Log = Sebas::Log.for("supervisor")

      record HealthState, account_id : String, channel_type : String, status : String

      class Supervisor
        getter health : Hash(String, String)

        def initialize(@bus : ::Sebas::Platform::Bus::Bus? = nil)
          @adapters = [] of Channels::ChannelAdapter
          @fingerprint_owner = Hash(String, String).new
          @parked = Set(String).new
          @health = {} of String => String
          @last_health = {} of String => String
          @mutex = Mutex.new
          @running = Atomic(Bool).new(false)
        end

        # 注册账号适配器；同渠道同凭据的第二个账号 park 拒启（Hermes 口径，不崩溃）
        def register(adapter : Channels::ChannelAdapter) : Symbol
          @mutex.synchronize do
            fingerprint = "#{adapter.channel_type}:#{adapter.credential_fingerprint}"
            if owner = @fingerprint_owner[fingerprint]?
              Log.warn { "duplicate credentials parked (account=#{adapter.account_id} duplicates=#{owner})" }
              @parked << adapter.account_id
              @health[adapter.account_id] = "parked"
              return :parked
            end
            @fingerprint_owner[fingerprint] = adapter.account_id
            @adapters << adapter
            @health[adapter.account_id] = "registered"
            :registered
          end
        end

        # 账号删除：drain 停止（§11.3 账号删除行）
        def remove_account(account_id : String) : Nil
          target = nil
          @mutex.synchronize do
            target = @adapters.find(&.account_id.==(account_id))
            @adapters.reject!(&.account_id.==(account_id))
            @health.delete(account_id)
            @last_health.delete(account_id)
          end
          target.try(&.stop)
        end

        def parked?(account_id : String) : Bool
          @mutex.synchronize { @parked.includes?(account_id) }
        end

        def start_all : Nil
          return if @running.swap(true)
          @mutex.synchronize { @adapters.each(&.start) }
          spawn(name: "sebas-supervisor") { watch_health }
        end

        def stop_all : Nil
          @running.set(false)
          @mutex.synchronize { @adapters.each(&.stop) }
        end

        def adapters : Array(Channels::ChannelAdapter)
          @mutex.synchronize { @adapters.dup }
        end

        # 健康观测：适配器 health 变化 → 上报（AccountEvent 入总线，管理面可见）
        private def watch_health : Nil
          while @running.get
            adapters.each do |adapter|
              status = adapter.health
              next unless status_changed?(adapter, status)
              @mutex.synchronize { @health[adapter.account_id] = status }
              publish_transition(adapter, status)
            end
            sleep 2.seconds
          end
        end

        private def status_changed?(adapter : Channels::ChannelAdapter, status : String) : Bool
          @mutex.synchronize do
            changed = @last_health[adapter.account_id]? != status
            @last_health[adapter.account_id] = status
            changed
          end
        end

        private def publish_transition(adapter : Channels::ChannelAdapter, status : String) : Nil
          Log.info { "account #{adapter.account_id} health: #{status}" }
          bus = @bus
          return unless bus
          bus.publish(Bus::AccountEvent.new(
            "supervisor:#{adapter.account_id}:#{Time.utc.to_unix_ms}",
            adapter.channel_type, adapter.account_id, "health.#{status}"
          ))
        rescue ::Exception
          nil # 总线满不阻塞监督循环
        end
      end
    end
  end
end
