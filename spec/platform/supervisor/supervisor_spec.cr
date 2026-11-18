require "spec"
require "../../../src/platform/supervisor/supervisor"

# 假适配器：可控 health 序列 + 凭据指纹
class FakeSupervisedAdapter < ::Sebas::Channels::ChannelAdapter
  property health_status : String = "offline"
  getter started = Channel(Nil).new(4)
  getter stopped = Channel(Nil).new(4)

  def initialize(account_id : String, @fingerprint : String? = nil)
    super("email", account_id)
  end

  def credential_fingerprint : String
    @fingerprint || account_id
  end

  def health : String
    @health_status
  end

  def start : Nil
    @health_status = "online"
    @started.send(nil)
  end

  def stop : Nil
    @health_status = "stopped"
    @stopped.send(nil)
  end

  def send(peer : String, content : String, idempotency_key : String? = nil) : ::Sebas::Channels::SendResult
    ::Sebas::Channels::SendResult.success
  end
end

def wait_for(seconds : Time::Span = 5.seconds, &condition : -> Bool) : Bool
  deadline = Time.instant + seconds
  until Time.instant > deadline
    return true if condition.call
    sleep 10.milliseconds
  end
  condition.call
end

module Sebas
  describe "account supervisor (M1-WP2)" do
    it "starts registered adapters and tracks health transitions" do
      bus = Platform::Bus::Bus.new(64)
      supervisor = Platform::Supervisor::Supervisor.new(bus)
      adapter = FakeSupervisedAdapter.new("acc-1")
      supervisor.register(adapter).should eq(:registered)

      supervisor.start_all
      wait_for { adapter.health_status == "online" }
      wait_for { supervisor.health["acc-1"]? == "online" }.should be_true

      # 首次上线转换 → AccountEvent 上报（管理面可见）
      online_event = bus.receive?(5.seconds)
      online_event = online_event.should be_a(Platform::Bus::AccountEvent)
      online_event.kind.should eq("health.online")

      # 健康变化 → 第二条上报
      adapter.health_status = "backoff"
      event = bus.receive?(5.seconds)
      event = event.should be_a(Platform::Bus::AccountEvent)
      event.account_id.should eq("acc-1")
      event.kind.should eq("health.backoff")
      bus.close
      supervisor.stop_all
    end

    it "parks duplicate credentials instead of crashing (§5.1/§10.1)" do
      supervisor = Platform::Supervisor::Supervisor.new
      a = FakeSupervisedAdapter.new("acc-a", "fp-secret-1")
      b = FakeSupervisedAdapter.new("acc-b", "fp-secret-1") # 同渠道同凭据
      c = FakeSupervisedAdapter.new("acc-c", "fp-secret-2")
      supervisor.register(a).should eq(:registered)
      supervisor.register(b).should eq(:parked)
      supervisor.register(c).should eq(:registered)
      supervisor.parked?("acc-b").should be_true
      supervisor.parked?("acc-c").should be_false
      supervisor.adapters.map(&.account_id).sort!.should eq(["acc-a", "acc-c"]) # parked 不启动
    end

    it "stops all adapters gracefully" do
      supervisor = Platform::Supervisor::Supervisor.new
      adapters = Array.new(3) { |i| FakeSupervisedAdapter.new("acc-#{i}") }
      adapters.each { |a| supervisor.register(a) }
      supervisor.start_all
      wait_for { adapters.all? { |a| a.health_status == "online" } }.should be_true
      supervisor.stop_all
      wait_for { adapters.all? { |a| a.health_status == "stopped" } }.should be_true
      adapters.each(&.health_status.should(eq("stopped")))
    end
  end
end
