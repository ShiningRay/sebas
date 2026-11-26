require "spec"
require "../../src/channels/email/imap_client"
require "../../src/channels/email/smtp_client"
require "../../src/channels/email/adapter"
require "../support/fake_imap_server"
require "../support/fake_smtp_server"

def wait_for(seconds : Time::Span = 5.seconds, &condition : -> Bool) : Bool
  deadline = Time.instant + seconds
  until Time.instant > deadline
    return true if condition.call
    sleep 10.milliseconds
  end
  condition.call
end

module Sebas
  describe "email channel (M0-WP4)" do
    it "markdown_to_text strips emphasis and keeps link URLs (A8)" do
      md = "# Title\n**bold** and *italic* and [link](https://x.y/a)\n![alt](https://x.y/i.png)"
      text = Channels::Common.markdown_to_text(md)
      text.should contain("Title")
      text.should contain("bold")
      text.should contain("link (https://x.y/a)")
      text.should contain("alt (https://x.y/i.png)")
      text.should_not contain("**")
    end

    it "TokenProvider caches with refresh buffer and invalidates (M1-WP3 前置语义)" do
      calls = 0
      provider = Channels::Common::CachedTokenProvider.new(refresh_buffer: 30.minutes) do
        calls += 1
        Channels::Common::Token.new("t#{calls}", Time.utc + 2.hours)
      end
      provider.token.value.should eq("t1")
      provider.token.value.should eq("t1") # 缓存命中
      calls.should eq(1)
      provider.invalidate
      provider.token.value.should eq("t2") # 失效重取
      calls.should eq(2)
    end

    it "sends IMAP commands with CRLF line endings (RFC 3501)" do
      # 回归：IO#puts 只写 "\n"，Gmail/QQ/Outlook 对 LF 命令行不响应（读超时）
      server = FakeImapServer.new
      server.add_mail("1", "alice@example.com", "hi", "body")
      server.serve
      begin
        client = Channels::Email::ImapClient.new("127.0.0.1", server.port, "u", "p", tls: false)
        client.login
        client.select
        client.logout
        client.close
        raw = server.raw_commands
        raw.should_not be_empty
        raw.each(&.should(end_with("\r\n")))
      ensure
        server.close
      end
    end

    it "sends SMTP commands and DATA frames with CRLF line endings (RFC 5321)" do
      # 回归：QQ SMTP 对 LF 的 EHLO 直接 502；DATA 段也须按 CRLF 分帧
      server = FakeSmtpServer.new
      server.serve
      begin
        client = Channels::Email::SmtpClient.new("127.0.0.1", server.port, "u", "p", tls_mode: "none")
        client.send_mail("me@example.com", "you@example.com", "hi", "line1\nline2")
        client.close
        raw = server.raw_lines
        raw.should_not be_empty
        raw.each(&.should(end_with("\r\n")))
        server.mails.first[:payload].should contain("line1\r\nline2")
      ensure
        server.close
      end
    end

    it "dot-stuffs a body line that starts with a dot" do
      server = FakeSmtpServer.new
      server.serve
      begin
        client = Channels::Email::SmtpClient.new("127.0.0.1", server.port, "u", "p", tls_mode: "none")
        client.send_mail("me@example.com", "you@example.com", "hi", ".hidden\n..double")
        client.close
        # fake 服务端按 RFC 逆点填充：往返后正文应与原文一致；
        # 客户端若漏做点填充，".hidden" 会被服务端剥成 "hidden"
        payload = server.mails.first[:payload]
        payload.should contain("\r\n.hidden\r\n")
        payload.should contain("\r\n..double\r\n")
      ensure
        server.close
      end
    end

    it "fetches messages over IMAP against the fake server" do
      server = FakeImapServer.new
      server.add_mail("1", "alice@example.com", "hi", "first body")
      server.add_mail("2", "bob@example.com", "yo", "second body")
      server.serve
      begin
        client = Channels::Email::ImapClient.new("127.0.0.1", server.port, "u", "p", tls: false)
        client.login
        client.select
        client.last_uidvalidity.should eq("1")
        mails = client.fetch_since("0")
        mails.size.should eq(2)
        mails[0].from.should eq("alice@example.com")
        mails[0].body.should eq("first body")
        mails[1].uid.should eq("2")
        client.logout
        client.close
      ensure
        server.close
      end
    end

    it "publishes inbound messages to the bus on EXISTS (收信入总线)" do
      server = FakeImapServer.new
      # 历史先入 1 封，连接建立后才到新邮件——新邮件才是要投总线的
      server.add_mail("1", "old@example.com", "old", "history should not be replayed")
      server.serve

      account = Platform::Config::EmailAccount.from_yaml(
        "id: test-mailbox\nplatform: 127.0.0.1\nreceive: imap-idle\ncredentials: { user: u, password: p }"
      )
      bus = Platform::Bus::Bus.new(8)
      adapter = Channels::Email::EmailChannelAdapter.new(
        account, bus, idle_poll: 2.seconds,
        imap_host: "127.0.0.1", imap_port: server.port, imap_tls: false,
        smtp_host: "127.0.0.1", smtp_port: 1, smtp_tls: "none"
      )
      adapter.start
      # 等 adapter 登录并进入 IDLE 后再投递新邮件，模拟真实到达时序
      wait_for(3.seconds) { server.seen_commands.any?(&.includes?("IDLE")) }.should be_true
      server.add_mail("2", "carol@example.com", "PR merged", "looks good to me")
      event = bus.receive?(5.seconds)
      adapter.stop
      begin
        msg = event.should be_a(Platform::Bus::InboundMessage)
        msg.account_id.should eq("test-mailbox")
        msg.peer.should eq("carol@example.com")
        msg.content.should eq("looks good to me")
        msg.event_id.should eq("email:test-mailbox:2")
      ensure
        bus.close
        server.close
      end
    end

    it "skips pre-existing mail on first connect (不重放历史)" do
      # 回归：last_uid 曾硬编码 "0"，332 封历史会被逐封重放进总线并触发回信
      server = FakeImapServer.new
      30.times { |i| server.add_mail((i + 1).to_s, "bulk#{i}@example.com", "old #{i}", "history #{i}") }
      server.serve

      account = Platform::Config::EmailAccount.from_yaml(
        "id: test-mailbox\nplatform: 127.0.0.1\nreceive: imap-idle\ncredentials: { user: u, password: p }"
      )
      bus = Platform::Bus::Bus.new(64)
      adapter = Channels::Email::EmailChannelAdapter.new(
        account, bus, idle_poll: 2.seconds,
        imap_host: "127.0.0.1", imap_port: server.port, imap_tls: false,
        smtp_host: "127.0.0.1", smtp_port: 1, smtp_tls: "none"
      )
      adapter.start
      wait_for(3.seconds) { server.seen_commands.any?(&.includes?("IDLE")) }.should be_true
      # 新邮件到达：只应看到这一封，历史 30 封不得出现
      server.add_mail("31", "fresh@example.com", "new", "just arrived")
      event = bus.receive?(5.seconds)
      adapter.stop
      begin
        msg = event.should be_a(Platform::Bus::InboundMessage)
        msg.event_id.should eq("email:test-mailbox:31")
        bus.receive?(200.milliseconds).should be_nil
      ensure
        bus.close
        server.close
      end
    end

    it "delivers outbound mail through SMTP (发信出站投递)" do
      server = FakeSmtpServer.new
      server.serve
      account = Platform::Config::EmailAccount.from_yaml(
        "id: test-mailbox\nplatform: 127.0.0.1\nreceive: imap-idle\nsmtp: { port: 0, tls: none }\ncredentials: { user: me@example.com, password: p }"
      )
      bus = Platform::Bus::Bus.new(4)
      adapter = Channels::Email::EmailChannelAdapter.new(
        account, bus, imap_host: "127.0.0.1", imap_port: 1, imap_tls: false,
        smtp_host: "127.0.0.1", smtp_port: server.port, smtp_tls: "none"
      )
      result = adapter.send("friend@example.com", "**hi** there", idempotency_key: "send:acc1:m1")
      result.ok?.should be_true
      wait_for { server.mails.size == 1 }.should be_true
      mail = server.mails.first
      mail[:from].should eq("me@example.com")
      mail[:to].should eq("friend@example.com")
      mail[:payload].should contain("Subject: Sebas")
      mail[:payload].should contain("hi there") # markdown 转纯文本
      mail[:payload].should_not contain("**")
      bus.close
      server.close
    end

    it "reports failed outbound sends as values" do
      account = Platform::Config::EmailAccount.from_yaml(
        "id: test-mailbox\nplatform: 127.0.0.1\nreceive: imap-idle\nsmtp: { port: 0, tls: none }\ncredentials: { user: me@example.com, password: p }"
      )
      bus = Platform::Bus::Bus.new(4)
      adapter = Channels::Email::EmailChannelAdapter.new(
        account, bus, imap_host: "127.0.0.1", imap_port: 1, imap_tls: false,
        smtp_host: "127.0.0.1", smtp_port: 1, smtp_tls: "none" # 端口 1 无服务 → 连接失败
      )
      result = adapter.send("x@example.com", "hello")
      result.ok?.should be_false
      result.error.should_not be_nil
      bus.close
    end
  end
end
