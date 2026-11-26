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
        Log = Sebas::Log.for("channels.email")

        getter health : String

        # 收信游标（进程内）：与记录它时的 UIDVALIDITY 绑定。UID 只在同一
        # UIDVALIDITY 下跨会话可比（RFC 3501 §2.3.1.1），服务端一旦换命名空间，
        # 旧游标会屏蔽新编号的邮件，必须作废重建。
        # - 首次连接：以 SELECT 的 UIDNEXT - 1 为基线，跳过既有历史——否则整个
        #   INBOX 会被逐封当新邮件重放进总线并逐封回信。
        # - 同 UIDVALIDITY 重连：沿用已推进的游标补收，断线窗口内的邮件不丢。
        # - UIDVALIDITY 变化：游标作废，重新以新命名空间的 UIDNEXT 为基线。
        # 进程重启后基线重新建立，停机期间收到的邮件不补投（持久化游标待 M1）。
        @last_uid : Int64? = nil
        @cursor_uidvalidity : String? = nil
        @backoff : Time::Span

        def initialize(account : Platform::Config::EmailAccount, @bus : Platform::Bus::Bus,
                       provider : Common::TokenProvider? = nil, idle_poll : Time::Span = 29.minutes,
                       imap_host : String? = nil, imap_port : Int32 = 993, imap_tls : Bool = true,
                       smtp_host : String? = nil, smtp_port : Int32? = nil, smtp_tls : String? = nil,
                       backoff : Time::Span = 5.seconds)
          super("email", account.id)
          @account = account
          @provider = provider || Common::StaticTokenProvider.new(account.credentials["password"]? || "")
          @idle_poll = idle_poll
          @backoff = backoff
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
              Log.warn { "imap session error (account=#{@account.id}): #{ex.message}; backoff #{@backoff}" }
              @health = "backoff"
              sleep @backoff
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
          Log.error { "imap connect failed (account=#{@account.id}): #{ex.message}; backoff #{@backoff}" }
          @health = "backoff"
          sleep @backoff
          nil
        end

        private def idle_session(client : ImapClient) : Nil
          establish_baseline(client)
          # 先把断线窗口里到的邮件补收掉，再进 IDLE——IDLE 只在邮件数变化时
          # 推 EXISTS（RFC 2177），不保证重发 SELECT 已通报的状态，光等
          # EXISTS 会让「断线期间到信、重连后不再到信」永久漏收。
          drain_inbox(client)
          while @running.get
            event = client.idle
            if event.nil?
              client.noop # IDLE 超时窗口到点：重发 IDLE（c1：≤29 分钟）
              next
            end
            next unless event.includes?("EXISTS")
            drain_inbox(client)
          end
        ensure
          client.logout
          client.close
        end

        # 定基线：首连或 UIDVALIDITY 变化时以 UIDNEXT - 1 起算（历史视为已读），
        # 否则沿用游标补收。UIDVALIDITY 不同则旧游标不可比，必须作废。
        # 没有 UIDNEXT 就建立不了可靠基线：此时宁可本次会话不投递，也不能退回
        # UID 0 —— 那会把整个历史分批当新件重放（RFC 3501 §6.3.1 要求 SELECT
        # 必带 UIDNEXT；真缺了说明服务端不规范，按不可用处理）。
        private def establish_baseline(client : ImapClient) : Nil
          uidvalidity = client.last_uidvalidity
          uidnext = client.last_uidnext
          if @cursor_uidvalidity != uidvalidity
            if uidvalidity && @cursor_uidvalidity
              Log.warn { "uidvalidity changed (#{@cursor_uidvalidity} -> #{uidvalidity}); resetting cursor (account=#{@account.id})" }
            end
            @cursor_uidvalidity = uidvalidity
            @last_uid = uidnext.try(&.-(1_i64))
            return
          end
          # 同命名空间：保留已推进的游标；首次连接（游标仍空）才取基线
          @last_uid ||= uidnext.try(&.-(1_i64))
        end

        # 循环取批直到没有新邮件：单批 FETCH_BATCH 上限之上还要继续，否则
        # 积压超过一批时新邮件永远排在老邮件后面取不到。
        private def drain_inbox(client : ImapClient) : Nil
          loop do
            # 每轮重读游标：循环内 advance_cursor 会推进它，用快照会把同一封
            # 重复投递，直到耗尽 FETCH_BATCH 上限才停。
            current = @last_uid
            if current.nil?
              Log.warn { "no UIDNEXT baseline; skip fetch this session (account=#{@account.id})" }
              return
            end
            mails = client.fetch_since(current.to_s, ImapClient::FETCH_BATCH)
            break if mails.empty?
            mails.each do |mail|
              advance_cursor(mail.uid.to_i64)
              publish_inbound(mail)
            end
          end
        end

        # 游标只前进不后退（服务端 UID 单调递增，回退意味着数据异常）
        private def advance_cursor(uid : Int64) : Nil
          current = @last_uid
          @last_uid = uid if current.nil? || uid > current
        end

        private def publish_inbound(mail : MailSummary) : Nil
          if self_sent?(mail.from)
            # 自己发出的信被 IMAP 收回（含副本同步、自投递测试）：并入站会与自身
            # 无限对聊。游标照常推进，只是不投总线。
            Log.info { "skip self-sent mail (account=#{@account.id}, uid=#{mail.uid}, subject=#{mail.subject})" }
            return
          end
          @bus.publish(Platform::Bus::InboundMessage.new(
            event_id: event_id_for(mail.uid),
            channel_type: "email",
            account_id: @account.id,
            peer: mail.from,
            content: mail.body
          ))
          @health = "online"
        end

        # event_id 必须带上 UIDVALIDITY：换命名空间后 UID 会从头复用，只按
        # 「账号 + UID」编号会与已投递事件撞主键（intents.id / session_inputs.event_id），
        # 新邮件被当成重复投递丢弃。无 UIDVALIDITY 时退化为旧格式。
        private def event_id_for(uid : String) : String
          if namespace = @cursor_uidvalidity
            return "email:#{@account.id}:#{namespace}:#{uid}"
          end
          "email:#{@account.id}:#{uid}"
        end

        # 发件人是否就是本账号（大小写不敏感；角括号与显示名由 from_address 归一）
        private def self_sent?(from : String) : Bool
          mine = smtp_from.strip.downcase
          return false if mine.empty?
          from_address(from).downcase == mine
        end

        private def from_address(from : String) : String
          if start = from.index('<')
            finish = from.index('>', start)
            return from[(start + 1)...finish] if finish
          end
          from.strip
        end

        private def smtp_client : SmtpClient
          SmtpClient.new(@smtp_host, @smtp_port, smtp_from, @provider.token.value, tls_mode: @smtp_tls)
        end
      end
    end
  end
end
