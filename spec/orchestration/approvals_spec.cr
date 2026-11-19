require "spec"
require "file_utils"
require "../../src/orchestration/approvals/approvals"
require "../../src/platform/store/store"

def approval_tmp_store
  dir = Path[ENV["TEMP"], "sebas-approval-spec", Random::Secure.hex(4)]
  FileUtils.rm_rf(dir)
  ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
end

module Sebas
  describe "approval center (M2-WP4)" do
    after_each do
      # 恢复真实时钟，避免污染其他用例
      ::Sebas::Orchestration::Approvals.clock = -> { Time.utc }
    end

    it "denies on timeout with injected clock fast-forward (§14 M2 验收第 2 条)" do
      virtual = Time.utc(2026, 11, 19, 12, 0, 0)
      ::Sebas::Orchestration::Approvals.clock = -> { virtual }

      # 后台 fiber：1 秒（虚拟时钟快进 1 小时）后放行虚拟时钟
      spawn do
        sleep 1.seconds
        virtual_copy = virtual + 1.hours
        ::Sebas::Orchestration::Approvals.clock = -> { virtual_copy }
      end

      center = ::Sebas::Orchestration::Approvals::Center.new
      start = Time.instant
      decision = center.request("message.send", %({"peer": "x"}), "run:t1", false, "manual", timeout_seconds: 600)
      elapsed = Time.instant - start
      decision.approved.should be_false
      decision.reason.should contain("timeout deny")
      elapsed.should be < 3.seconds # 注入时钟快进：不等真实 600s
    end

    it "approves when the operator approves via dual entry API (人工放行)" do
      store = approval_tmp_store
      center = ::Sebas::Orchestration::Approvals::Center.new(store)
      done = Channel(::Sebas::Orchestration::Approvals::Decision).new
      spawn do
        done.send(center.request("memory.save", %({"key": "k"}), "run:t2", false, "manual"))
      end
      # 等待 pending 出现后人工批准
      deadline = Time.instant + 5.seconds
      approved_ok = false
      while Time.instant < deadline
        pending = center.pending_requests
        if pending.size == 1
          center.approve(pending.first.id, "boss")
          approved_ok = true
          break
        end
        sleep 50.milliseconds
      end
      approved_ok.should be_true
      decision = nil
      select
      when d = done.receive
        decision = d
      when timeout 5.seconds
        fail("no approval decision within 5s")
      end
      decision.approved.should be_true
      decision.reason.should contain("approved by boss")
      store.close
    end

    it "honors operator deny (人工拒绝)" do
      store = approval_tmp_store
      center = ::Sebas::Orchestration::Approvals::Center.new(store)
      done = Channel(::Sebas::Orchestration::Approvals::Decision).new
      spawn do
        done.send(center.request("message.send", %({"peer": "y"}), "run:t3", false, "manual"))
      end
      deadline = Time.instant + 5.seconds
      denied_ok = false
      while Time.instant < deadline
        pending = center.pending_requests
        if pending.size == 1
          center.deny(pending.first.id, "boss")
          denied_ok = true
          break
        end
        sleep 50.milliseconds
      end
      denied_ok.should be_true
      decision = nil
      select
      when d = done.receive
        decision = d
      when timeout 5.seconds
        fail("no deny decision within 5s")
      end
      decision.approved.should be_false
      decision.reason.should contain("denied by boss")
      store.close
    end

    it "denies unattended runs by default (无人值守 deny)" do
      center = ::Sebas::Orchestration::Approvals::Center.new
      decision = center.request("message.send", %({"peer": "z"}), "run:t4", true, "manual")
      decision.approved.should be_false
      decision.reason.should contain("unattended")
    end

    it "blocks hardline commands in every mode (hardline 不可 override)" do
      center = ::Sebas::Orchestration::Approvals::Center.new
      {"manual", "off"}.each do |mode|
        decision = center.request("command.run", %({"cmd": "rm -rf /"}), "run:t5", true, mode)
        decision.approved.should be_false
        decision.reason.should contain("hardline")
        attended = center.request("command.run", %({"cmd": "Format-Volume -DriveLetter C"}), "run:t6", false, mode)
        attended.approved.should be_false
        attended.reason.should contain("hardline")
      end
    end

    it "passes through mode=off but still blocks hardline (off 放行)" do
      center = ::Sebas::Orchestration::Approvals::Center.new
      decision = center.request("memory.save", %({"key": "k"}), "run:t7", false, "off")
      decision.approved.should be_true
      decision.reason.should eq("mode=off")
    end

    it "replays decisions from memo (§7.3 决策级幂等)" do
      store = approval_tmp_store
      center = ::Sebas::Orchestration::Approvals::Center.new(store)
      first = center.request("memory.save", %({"key": "memo"}), "run:t8", false, "manual", timeout_seconds: 1)
      # timeout deny（无人批准，1 秒后超时）
      first.approved.should be_false
      # 重放同一请求：memo 决策（timeout deny）直接返回，不再等待
      replay = center.request("memory.save", %({"key": "memo"}), "run:t8", false, "manual", timeout_seconds: 1)
      replay.approved.should be_false
      replay.reason.should contain("memo")
      store.close
    end
  end
end
