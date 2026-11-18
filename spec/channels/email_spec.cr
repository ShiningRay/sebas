require "spec"
require "../../src/channels/email/imap_client"
require "../../src/channels/email/smtp_client"
require "../../src/channels/email/adapter"
require "../support/fake_imap_server"
require "../support/fake_smtp_server"

def wait_for(seconds : Time::Span = 5.seconds, &condition : -> Bool) : Bool
  deadline = Time.monotonic + seconds
  until Time.monotonic > deadline
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
      server.add_mail("1", "carol@example.com", "PR merged", "looks good to me")
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
      event = bus.receive?(3.seconds)
      adapter.stop
      begin
        msg = event.should be_a(Platform::Bus::InboundMessage)
        msg.account_id.should eq("test-mailbox")
        msg.peer.should eq("carol@example.com")
        msg.content.should eq("looks good to me")
        msg.event_id.should eq("email:test-mailbox:1")
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
