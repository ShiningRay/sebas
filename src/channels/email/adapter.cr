require "../../platform/bus/bus"
require "../base"
require "./imap_client"
require "./smtp_client"
require "../common/token_provider"
require "../common/markdown"
require "../../platform/config/schema"

# email 渠道适配器（M0-WP4）：IMAP IDLE 收信 → InboundMessage 入总线；SMTP 出站。
# fiber-per-account（§4.1）；IDLE ≤29min 重发；UIDVALIDITY 变化全量重扫口径留 M1 补。
module Sebas
  module Channels
    module Email
      class EmailChannelAdapter < ChannelAdapter
        Log = Sebas::Log.for("sebas.channels.email")

        getter health : String

        def initialize(account : Platform::Config::EmailAccount, @bus : Platform::Bus::Bus,
                       provider : Common::TokenProvider? = nil, idle_poll : Time::Span = 29.minutes,
                       imap_host : String? = nil, imap_port : Int32 = 993, imap_tls : Bool = true,
                       smtp_host : String? = nil, smtp_port : Int32? = nil, smtp_tls : String? = nil)
          super("email", account.id)
          @account = account
          @provider = provider || Common::StaticTokenProvider.new(account.credentials["password"]? || "")
          @idle_poll = idle_poll
          @imap_host = imap_host || account.platform || ""
          @imap_port = imap_port
          @imap_tls = imap_tls
          @smtp_host = smtp_host || account.platform || ""
          @smtp_port = smtp_port || account.smtp.try(&.port) || 465
          @smtp_tls = smtp_tls || account.smtp.try(&.tls) || "implicit"
          @running = Atomic(Bool).new(false)
          @health = "offline"
        end

        # 启动收信循环（幂等防御重复 start）
        def start : Nil
          return if @running.swap(true)
          spawn(name: "sebas-account:email:#{@account.id}") do
            receive_loop
          end
        end

        def stop : Nil
          @running.set(false)
          # 断开由 receive_loop 下轮检测 running=false 完成；无长连接句柄暴露
        end

        # 出站：markdown → text/plain（A8），SMTP 465/587
        def send(peer : String, content : String, idempotency_key : String? = nil) : SendResult
          smtp = smtp_client
          begin
            smtp.send_mail(smtp_from, peer, "Sebas", Common.markdown_to_text(content))
            Log.info { "email sent to #{peer} (account=#{@account.id}, key=#{idempotency_key || "none"})" }
            SendResult.success
          ensure
            smtp.close
          end
        rescue ex : SmtpError | ::Socket::Error | IO::Error
          Log.error { "email send failed: #{ex.message}" }
          SendResult.error(ex.message || ex.class.to_s)
        end

        # 连接信息（收发地址）
        def smtp_from : String
          @account.credentials["user"]? || ""
        end

        private def receive_loop : Nil
          while @running.get
            client = connect
            next unless client
            begin
              idle_session(client)
            rescue ex : ImapError | ::Socket::Error | IO::Error
              Log.warn { "imap session error (account=#{@account.id}): #{ex.message}; backoff 5s" }
              @health = "backoff"
              sleep 5.seconds
            end
          end
        end

        private def connect : ImapClient?
          account = @account
          client = ImapClient.new(
            @imap_host, @imap_port,
            account.credentials["user"]? || "", @provider.token.value,
            tls: @imap_tls, read_timeout: @idle_poll + 1.minutes
          )
          client.login
          client.select
          @health = "online"
          client
        rescue ex : ImapError | ::Socket::Error
          Log.error { "imap connect failed (account=#{@account.id}): #{ex.message}; backoff 5s" }
          @health = "backoff"
          sleep 5.seconds
          nil
        end

        private def idle_session(client : ImapClient) : Nil
          last_uid = "0"
          while @running.get
            event = client.idle
            if event.nil?
              client.noop # IDLE 超时窗口到点：重发 IDLE（c1：≤29 分钟）
              next
            end
            next unless event.includes?("EXISTS")
            client.fetch_since(last_uid).each do |mail|
              last_uid = mail.uid if mail.uid.to_i64 > last_uid.to_i64
              publish_inbound(mail)
            end
          end
        ensure
          client.logout
          client.close
        end

        private def publish_inbound(mail : MailSummary) : Nil
          @bus.publish(Platform::Bus::InboundMessage.new(
            event_id: "email:#{@account.id}:#{mail.uid}",
            channel_type: "email",
            account_id: @account.id,
            peer: mail.from,
            content: mail.body
          ))
          @health = "online"
        end

        private def smtp_client : SmtpClient
          SmtpClient.new(@smtp_host, @smtp_port, smtp_from, @provider.token.value, tls_mode: @smtp_tls)
        end
      end
    end
  end
end
