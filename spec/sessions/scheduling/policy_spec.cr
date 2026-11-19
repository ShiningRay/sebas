require "spec"
require "yaml"
require "../../../src/sessions/scheduling/policy"
require "../../../src/platform/config/loader"

module SchedulingSpec
  def self.cfg(raw : String) : ::Sebas::Sessions::Scheduling::SessionPolicyConfig
    ::Sebas::Sessions::Scheduling::SessionPolicyConfig.from_yaml(raw)
  end

  def self.resolve(agent_raw : String? = nil, gateway_raw : String? = nil)
    gateway = gateway_raw ? cfg(gateway_raw) : nil
    agent = agent_raw ? cfg(agent_raw) : nil
    ::Sebas::Sessions::Scheduling::Policy.resolve_session(gateway, agent)
  end

  def self.workflow(batch_raw : String)
    ::Sebas::Sessions::Scheduling::Policy.resolve_workflow(cfg(batch_raw))
  end
end

describe Sebas::Sessions::Scheduling::Policy do
  describe "内置默认值（契约 §3.3）" do
    it "queue 为缺省 batch_mode、steer 关闭" do
      p = Sebas::Sessions::Scheduling::Policy.builtin
      p.batch_mode.should eq("queue")
      p.idle_ms.should eq(1000)
      p.max_wait_ms.should eq(5000)
      p.max_messages.should eq(20)
      p.max_bytes.should eq(32768)
      p.flush_on_turn_end?.should be_true
      p.group_by.should eq("sender")
      p.max_active_buckets.should eq(32)
      p.max_pending_batches.should eq(32)
      p.max_pending_bytes.should eq(262144)
      p.steer_enabled?.should be_false
      p.steer_debounce_ms.should eq(300)
      p.steer_max_pending_messages.should eq(16)
      p.steer_max_wait_ms.should eq(30000)
    end
  end

  describe "两作用域合并（§3.1：嵌套递归合并、标量整体覆盖）" do
    it "gateway.session 覆盖内置默认" do
      p = SchedulingSpec.resolve(gateway_raw: "batch_mode: debounce\ndebounce:\n  idle_ms: 2000")
      p.batch_mode.should eq("debounce")
      p.idle_ms.should eq(2000)
      p.max_wait_ms.should eq(5000) # 未提供字段继承默认
    end

    it "agent.session 只覆盖声明字段，其余继承 gateway" do
      p = SchedulingSpec.resolve(
        agent_raw: "debounce:\n  idle_ms: 3000\n  max_messages: 24\nsteer:\n  enabled: true",
        gateway_raw: "batch_mode: debounce\ndebounce:\n  idle_ms: 2000\n  max_bytes: 65536"
      )
      p.batch_mode.should eq("debounce")
      p.idle_ms.should eq(3000)    # agent 覆盖 gateway
      p.max_messages.should eq(24) # agent 覆盖默认
      p.max_bytes.should eq(65536) # gateway 覆盖默认
      p.steer_enabled?.should be_true
    end

    it "显式 false 覆盖默认 true（布尔不得被继承吞掉）" do
      p = SchedulingSpec.resolve(agent_raw: "debounce:\n  flush_on_turn_end: false")
      p.flush_on_turn_end?.should be_false
    end

    it "显式零值与缺省继承不混淆（idle_ms: 0 合法）" do
      p = SchedulingSpec.resolve(agent_raw: "debounce:\n  idle_ms: 0")
      p.idle_ms.should eq(0)
      p.max_wait_ms.should eq(5000) # 缺省仍继承
    end

    it "同一输入恒得同一 effective policy（纯函数）" do
      a = SchedulingSpec.resolve(agent_raw: "batch_mode: debounce\ndebounce:\n  idle_ms: 1500")
      b = SchedulingSpec.resolve(agent_raw: "batch_mode: debounce\ndebounce:\n  idle_ms: 1500")
      a.should eq(b)
    end
  end

  describe "workflow 作用域隔离（§3.1：不继承 gateway.session）" do
    it "gateway.session=debounce 时未声明 batch 的 workflow 仍逐事件" do
      p = SchedulingSpec.workflow("{}")
      p.batch_mode.should eq("queue")
    end

    it "workflow.batch 与会话策略同字段名，递归合并仅作用于该 workflow" do
      p = SchedulingSpec.workflow("batch_mode: debounce\ndebounce:\n  idle_ms: 500\n  max_wait_ms: 3000")
      p.batch_mode.should eq("debounce")
      p.idle_ms.should eq(500)
      p.max_wait_ms.should eq(3000)
      p.max_messages.should eq(20) # 未提供字段继承内置默认
    end

    it "workflow.batch 数值经 from_any 真实消费（不静默回落默认）" do
      node = YAML.parse("batch_mode: debounce\ndebounce:\n  idle_ms: 1500")
      cfg = Sebas::Sessions::Scheduling::SessionPolicyConfig.from_any(node)
      p = Sebas::Sessions::Scheduling::Policy.resolve_workflow(cfg)
      p.idle_ms.should eq(1500)
    end

    it "workflow.batch 数值超范围仍被校验（不因解析路径绕过硬范围）" do
      node = YAML.parse("batch_mode: debounce\ndebounce:\n  idle_ms: 99999")
      expect_raises(Sebas::Sessions::Scheduling::PolicyError, "idle_ms") do
        Sebas::Sessions::Scheduling::Policy.resolve_workflow(
          Sebas::Sessions::Scheduling::SessionPolicyConfig.from_any(node))
      end
    end
  end

  describe "非法配置快速失败（§3.4）" do
    it "非法枚举拒绝加载，不静默回退" do
      expect_raises(Sebas::Sessions::Scheduling::PolicyError, "batch_mode") do
        SchedulingSpec.resolve(agent_raw: "batch_mode: fifo")
      end
    end

    it "未知键拒绝加载（Strict）" do
      expect_raises(YAML::ParseException | Sebas::Sessions::Scheduling::PolicyError) do
        SchedulingSpec.resolve(agent_raw: "debounce:\n  idle_unknown: 5")
      end
    end
  end

  describe "硬范围表（§3.3，表驱动逐字段边界）" do
    bad_cases = [
      {"debounce:\n  idle_ms: 10001", "idle_ms"},
      {"debounce:\n  max_wait_ms: 0", "max_wait_ms"},
      {"debounce:\n  max_messages: 201", "max_messages"},
      {"debounce:\n  max_bytes: 100", "max_bytes"},
      {"debounce:\n  max_active_buckets: 300", "max_active_buckets"},
      {"steer:\n  debounce_ms: 5001", "steer.debounce_ms"},
      {"steer:\n  max_pending_messages: 101", "steer.max_pending_messages"},
      {"steer:\n  max_wait_ms: 300001", "steer.max_wait_ms"},
      {"debounce:\n  idle_ms: 5000\n  max_wait_ms: 4000", "max_wait_ms must be >= idle"},
      {"steer:\n  enabled: false\n  max_wait_ms: 100\n  debounce_ms: 500", "steer.max_wait_ms must be >= steer.debounce"},
    ]

    bad_cases.each do |(raw, tag)|
      it "拒绝 #{tag}" do
        expect_raises(Sebas::Sessions::Scheduling::PolicyError, tag.split(" ").first) do
          SchedulingSpec.resolve(agent_raw: raw)
        end
      end
    end

    good_cases = [
      "debounce:\n  idle_ms: 10000\n  max_wait_ms: 60000",
      "debounce:\n  max_messages: 1\n  max_bytes: 256",
      "steer:\n  enabled: true\n  debounce_ms: 0\n  max_wait_ms: 1",
    ]

    good_cases.each do |raw|
      it "接受边界合法值 #{raw.gsub("\n", " / ")}" do
        SchedulingSpec.resolve(agent_raw: raw) # 不抛即通过
      end
    end
  end

  describe "功能关闭时显式字段仍校验（§3.4）" do
    it "steer 关闭但显式 max_wait_ms 超范围仍拒绝" do
      expect_raises(Sebas::Sessions::Scheduling::PolicyError, "steer.max_wait_ms") do
        SchedulingSpec.resolve(agent_raw: "steer:\n  enabled: false\n  max_wait_ms: 999999")
      end
    end
  end

  describe "配置树校验入口（loader 集成）" do
    it "gateway.session 非法 → 带作用域前缀的错误行" do
      gateway = SchedulingSpec.cfg("batch_mode: fifo")
      errors = Sebas::Sessions::Scheduling::Policy.validate_config_errors(gateway, {} of String => Sebas::Sessions::Scheduling::SessionPolicyConfig?)
      errors.size.should be > 0
      errors.any?(&.starts_with?("gateway.session.")).should be_true
    end

    it "agent.session 非法 → agents.<name>.session 前缀" do
      agents = {"main" => SchedulingSpec.cfg("debounce:\n  max_bytes: 5")}
      errors = Sebas::Sessions::Scheduling::Policy.validate_config_errors(nil, agents)
      errors.any?(&.starts_with?("agents.main.session.")).should be_true
    end

    it "loader：非法 gateway.session 拒启（ValidationError）" do
      yaml = <<-YAML
        channels: {}
        agents:
          main:
            model: deepseek/chat
        bindings: []
        gateway:
          session:
            batch_mode: fifo
        YAML
      expect_raises(Sebas::Platform::Config::ValidationError, "gateway.session") do
        Sebas::Platform::Config::Loader.from_content(yaml)
      end
    end

    it "loader：合法 session 配置解析通过" do
      yaml = <<-YAML
        channels: {}
        agents:
          main:
            model: deepseek/chat
            session:
              batch_mode: debounce
              debounce: { idle_ms: 1200, max_wait_ms: 6000 }
              steer: { enabled: true }
        bindings: []
        gateway:
          session:
            queue: { max_pending_batches: 64 }
        YAML
      config = Sebas::Platform::Config::Loader.from_content(yaml)
      config.gateway.session.should_not be_nil
      config.agents["main"].session.should_not be_nil
    end
  end
end
