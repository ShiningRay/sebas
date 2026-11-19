require "spec"
require "../../../src/sessions/scheduling/envelope"

module EnvelopeSpec
  include Sebas::Sessions::Scheduling

  def self.policy(batch_mode : String = "debounce", idle_ms : Int64 = 1000_i64,
                  max_wait_ms : Int64 = 5000_i64, max_messages : Int64 = 20_i64,
                  max_bytes : Int64 = 32768_i64, flush_on_turn_end : Bool = true,
                  group_by : String = "sender") : PolicySnapshot
    PolicySnapshot.new(batch_mode, idle_ms, max_wait_ms, max_messages, max_bytes,
      flush_on_turn_end, group_by, 32_i64, 32_i64, 262144_i64,
      false, 300_i64, 16_i64, 30000_i64)
  end

  def self.acc(first : Int64, last : Int64, count : Int32 = 1, bytes : Int64 = 100_i64) : BatchAccumulator
    BatchAccumulator.new(first, last, count, bytes)
  end

  def self.k(group_by : String, session_key : String, sender : String, source : String, ctx : String) : String
    Sebas::Sessions::Scheduling.bucket_key(group_by, session_key, sender, source, ctx)
  end

  def self.bid(session_key : String, first_seq : Int64) : String
    Sebas::Sessions::Scheduling.batch_id_for(session_key, first_seq)
  end
end

describe Sebas::Sessions::Scheduling do
  describe "状态迁移表（§4.1）" do
    it "Input：accepted → batched → dispatched → done 合法" do
      Sebas::Sessions::Scheduling.valid_input_transition?(Sebas::Sessions::Scheduling::InputStatus::Accepted, Sebas::Sessions::Scheduling::InputStatus::Batched).should be_true
      Sebas::Sessions::Scheduling.valid_input_transition?(Sebas::Sessions::Scheduling::InputStatus::Batched, Sebas::Sessions::Scheduling::InputStatus::Dispatched).should be_true
      Sebas::Sessions::Scheduling.valid_input_transition?(Sebas::Sessions::Scheduling::InputStatus::Dispatched, Sebas::Sessions::Scheduling::InputStatus::Done).should be_true
      Sebas::Sessions::Scheduling.valid_input_transition?(Sebas::Sessions::Scheduling::InputStatus::Dispatched, Sebas::Sessions::Scheduling::InputStatus::Failed).should be_true
    end

    it "Input：跳跃迁移非法（accepted→done 折叠被禁止）" do
      Sebas::Sessions::Scheduling.valid_input_transition?(Sebas::Sessions::Scheduling::InputStatus::Accepted, Sebas::Sessions::Scheduling::InputStatus::Done).should be_false
      Sebas::Sessions::Scheduling.valid_input_transition?(Sebas::Sessions::Scheduling::InputStatus::Accepted, Sebas::Sessions::Scheduling::InputStatus::Dispatched).should be_false
    end

    it "Batch：collecting → sealed → queued → running → done 合法" do
      Sebas::Sessions::Scheduling.valid_batch_transition?(Sebas::Sessions::Scheduling::BatchStatus::Collecting, Sebas::Sessions::Scheduling::BatchStatus::Sealed).should be_true
      Sebas::Sessions::Scheduling.valid_batch_transition?(Sebas::Sessions::Scheduling::BatchStatus::Sealed, Sebas::Sessions::Scheduling::BatchStatus::Queued).should be_true
      Sebas::Sessions::Scheduling.valid_batch_transition?(Sebas::Sessions::Scheduling::BatchStatus::Queued, Sebas::Sessions::Scheduling::BatchStatus::Running).should be_true
      Sebas::Sessions::Scheduling.valid_batch_transition?(Sebas::Sessions::Scheduling::BatchStatus::Running, Sebas::Sessions::Scheduling::BatchStatus::Done).should be_true
    end

    it "Batch：竞态迁移非法（collecting→running 直接跳过封冻）" do
      Sebas::Sessions::Scheduling.valid_batch_transition?(Sebas::Sessions::Scheduling::BatchStatus::Collecting, Sebas::Sessions::Scheduling::BatchStatus::Running).should be_false
      Sebas::Sessions::Scheduling.valid_batch_transition?(Sebas::Sessions::Scheduling::BatchStatus::Collecting, Sebas::Sessions::Scheduling::BatchStatus::Queued).should be_false
    end

    it "Steer：accepted → injected / queued / expired / rejected 合法" do
      Sebas::Sessions::Scheduling.valid_steer_transition?(Sebas::Sessions::Scheduling::SteerStatus::Accepted, Sebas::Sessions::Scheduling::SteerStatus::Injected).should be_true
      Sebas::Sessions::Scheduling.valid_steer_transition?(Sebas::Sessions::Scheduling::SteerStatus::Accepted, Sebas::Sessions::Scheduling::SteerStatus::Queued).should be_true
      Sebas::Sessions::Scheduling.valid_steer_transition?(Sebas::Sessions::Scheduling::SteerStatus::Accepted, Sebas::Sessions::Scheduling::SteerStatus::Expired).should be_true
      Sebas::Sessions::Scheduling.valid_steer_transition?(Sebas::Sessions::Scheduling::SteerStatus::Accepted, Sebas::Sessions::Scheduling::SteerStatus::Rejected).should be_true
      Sebas::Sessions::Scheduling.valid_steer_transition?(Sebas::Sessions::Scheduling::SteerStatus::Queued, Sebas::Sessions::Scheduling::SteerStatus::Injected).should be_false
    end
  end

  describe "seal 条件评估（§4.3 纯函数）" do
    it "显式 flush 立即封冻" do
      r = Sebas::Sessions::Scheduling.eval_seal(EnvelopeSpec.acc(0, 0), EnvelopeSpec.policy, 100, explicit_flush: true)
      r.should eq(Sebas::Sessions::Scheduling::SealReason::Flush)
    end

    it "flush_on_turn_end：前一批 turn 结束即封冻，不再白等 idle" do
      r = Sebas::Sessions::Scheduling.eval_seal(EnvelopeSpec.acc(0, 100), EnvelopeSpec.policy, 200, prior_turn_ended: true)
      r.should eq(Sebas::Sessions::Scheduling::SealReason::TurnEnd)
    end

    it "flush_on_turn_end=false 时不因 turn 结束封冻" do
      p = EnvelopeSpec.policy(flush_on_turn_end: false)
      Sebas::Sessions::Scheduling.eval_seal(EnvelopeSpec.acc(0, 100), p, 200, prior_turn_ended: true).should be_nil
    end

    it "达到 max_bytes 立即封冻" do
      r = Sebas::Sessions::Scheduling.eval_seal(EnvelopeSpec.acc(0, 0, bytes: 32768_i64), EnvelopeSpec.policy, 10)
      r.should eq(Sebas::Sessions::Scheduling::SealReason::Bytes)
    end

    it "达到 max_messages 立即封冻" do
      r = Sebas::Sessions::Scheduling.eval_seal(EnvelopeSpec.acc(0, 0, count: 20), EnvelopeSpec.policy, 10)
      r.should eq(Sebas::Sessions::Scheduling::SealReason::Count)
    end

    it "max_wait 到时不被新消息重置（last_received 更新也封冻）" do
      r = Sebas::Sessions::Scheduling.eval_seal(EnvelopeSpec.acc(0, 4999, count: 2), EnvelopeSpec.policy, 5000)
      r.should eq(Sebas::Sessions::Scheduling::SealReason::MaxWait)
    end

    it "idle 到时封冻（可重置语义由 last_received 承载）" do
      r = Sebas::Sessions::Scheduling.eval_seal(EnvelopeSpec.acc(0, 1000), EnvelopeSpec.policy, 2000)
      r.should eq(Sebas::Sessions::Scheduling::SealReason::Idle)
    end

    it "idle_ms=0 时 idle 条件禁用（仅由其余条件封冻）" do
      p = EnvelopeSpec.policy(idle_ms: 0_i64)
      # now=1000：max_wait 未到、无 count/bytes 达标、无 flush —— idle 被禁用后应继续 collecting
      Sebas::Sessions::Scheduling.eval_seal(EnvelopeSpec.acc(0, 1000, count: 2, bytes: 500_i64), p, 1000).should be_nil
    end

    it "条件均未满足时继续 collecting" do
      Sebas::Sessions::Scheduling.eval_seal(EnvelopeSpec.acc(0, 990), EnvelopeSpec.policy, 1000).should be_nil
    end

    it "已 sealed 批次不再评估（无副作用）" do
      sealed = Sebas::Sessions::Scheduling::BatchAccumulator.new(0, 0, 1, 100_i64, sealed: true)
      Sebas::Sessions::Scheduling.eval_seal(sealed, EnvelopeSpec.policy, 999999, explicit_flush: true).should be_nil
    end
  end

  describe "字节预算 admission（§4.3）" do
    it "批内放得下 → append" do
      Sebas::Sessions::Scheduling.admit_decision(1000_i64, 500_i64, 32768_i64)
        .should eq(Sebas::Sessions::Scheduling::AdmitDecision::Append)
    end

    it "合并恰好到达上限 → append（== 不是 >）" do
      Sebas::Sessions::Scheduling.admit_decision(31768_i64, 1000_i64, 32768_i64)
        .should eq(Sebas::Sessions::Scheduling::AdmitDecision::Append)
    end

    it "合并超出剩余预算 → seal_then_new（先 seal 当前批，输入开新批不丢弃）" do
      Sebas::Sessions::Scheduling.admit_decision(20000_i64, 20000_i64, 32768_i64)
        .should eq(Sebas::Sessions::Scheduling::AdmitDecision::SealThenNew)
    end

    it "单条自身超限 → reject（不无限截断）" do
      Sebas::Sessions::Scheduling.admit_decision(0_i64, 40000_i64, 32768_i64)
        .should eq(Sebas::Sessions::Scheduling::AdmitDecision::Reject)
    end
  end

  describe "聚合桶键（§4.3 group_by）" do
    it "sender（默认）：不同发送者不同桶，不合并" do
      EnvelopeSpec.k("sender", "s1", "alice", "email", "dm").should_not eq(EnvelopeSpec.k("sender", "s1", "bob", "email", "dm"))
    end

    it "session：跨发送者同桶，但安全上下文不同仍隔离" do
      EnvelopeSpec.k("session", "s1", "alice", "email", "dm").should eq(EnvelopeSpec.k("session", "s1", "bob", "email", "dm"))
      EnvelopeSpec.k("session", "s1", "alice", "email", "dm").should_not eq(EnvelopeSpec.k("session", "s1", "alice", "email", "admin"))
    end

    it "不同 session_key 永不同桶" do
      EnvelopeSpec.k("sender", "s1", "alice", "email", "dm").should_not eq(EnvelopeSpec.k("sender", "s2", "alice", "email", "dm"))
    end
  end

  describe "batch_id 生成（§4.2：session + 持久序号，非文本 hash）" do
    it "同 session 不同首序号 → 不同 batch_id" do
      EnvelopeSpec.bid("s1", 1_i64).should_not eq(EnvelopeSpec.bid("s1", 2_i64))
    end

    it "同 session 同序号 → 相同 batch_id（幂等）" do
      EnvelopeSpec.bid("s1", 1_i64).should eq(EnvelopeSpec.bid("s1", 1_i64))
    end
  end
end
