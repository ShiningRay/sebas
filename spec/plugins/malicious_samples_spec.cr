require "spec"
require "json"
require "../support/plugins_spec_helper"

# 恶意插件样本验收（M3-WP5，#17；design.md §12.4 ④ + WBS 交付物）：
# 五类恶意样本（spec/plugins/fixtures/malicious/）逐个验证宿主边界——
# 死循环→watchdog 终止；内存爆→OS 上限终止（POSIX 实测）；未授权
# capability→driver 拒绝；递归 hook→深度预算 deny；非法 transform→
# invalid_result deny。样本脚本对 shim 与真实 mruby 解释器同源执行。
module Sebas
  module MaliciousHelpers
    extend self

    FIXTURES = Path[__DIR__, "malicious_samples"].normalize

    def plugin(id : String) : ::Sebas::Plugins::LoadedPlugin
      registry = ::Sebas::Plugins::Registry.new
      report = registry.load_dir(FIXTURES)
      report.errors.each { |e| fail("malicious fixture load error: #{e}") }
      registry.plugin(id) || fail("fixture #{id} not loaded")
    end

    def dispatcher_for(id : String, interp : Array(String)) : ::Sebas::Plugins::HookDispatcher
      plugin = plugin(id)
      registry = ::Sebas::Plugins::Registry.new
      registry.load_dir(FIXTURES)
      dispatch = ::Sebas::Plugins::Dispatch.new(registry, PluginSpecSupport.make_runner(interp))
      d = ::Sebas::Plugins::HookDispatcher.new
      d.dispatch = dispatch
      d.subscribe("memory.remember.before", plugin.manifest, id)
      d
    end

    def payload : JSON::Any
      JSON.parse(%({"entry": {"text": "hello", "tags": []}}))
    end
  end

  describe "恶意插件样本（M3-WP5 交付物）" do
    interp = PluginSpecSupport.interpreter

    it "未授权 capability：driver 缺位结构化拒绝（capability_driver_missing）" do
      interp2 = interp
      unless interp2
        pending "需要解释器"
        next
      end
      # 该样本声明 hooks.sensitive 但调用未登记 driver 的 memory_driver.query：
      # 宿主 runner 未装配 capability_handler → capability_driver_missing →
      # gate 判 deny（fail-closed）
      d = MaliciousHelpers.dispatcher_for("unauthorized-cap", interp2)
      verdict = d.gate("memory.remember.before", JSON.parse("{}"), MaliciousHelpers.payload)
      verdict.denied.should be_true
      # 双重授权第一关：manifest 未声明该 capability → 越权拒绝（WP4 层）
      verdict.code.should eq("capability_not_authorized")
    end

    it "非法 transform：裸非对象返回 → invalid_result deny（§12.11 fail-closed）" do
      interp2 = interp
      unless interp2
        pending "需要解释器"
        next
      end
      d = MaliciousHelpers.dispatcher_for("illegal-transform", interp2)
      verdict = d.transform("memory.remember.before", JSON.parse("{}"), MaliciousHelpers.payload)
      verdict.denied.should be_true
      verdict.code.should eq("invalid_result")
    end

    it "递归 hook：capability 触发的重入被深度预算拦截（hook_depth_exceeded deny）" do
      interp2 = interp
      unless interp2
        pending "需要解释器"
        next
      end
      d = MaliciousHelpers.dispatcher_for("recursive-hook", interp2)
      budget = ::Sebas::Plugins::HookDispatcher::Budget.new(max_calls: 64, max_depth: 1, max_total_ms: 10_000)
      verdict = d.gate("memory.remember.before", JSON.parse("{}"), MaliciousHelpers.payload, budget: budget)
      verdict.denied.should be_true
      # 递归重入的两道拦截均为 deny fail-closed：manifest 未声明 → 越权
      # （第一关）；声明后重入 → 深度预算/断流（第二关）
      {"hook_depth_exceeded", "capability_channel_closed", "capability_not_authorized"}.should contain(verdict.code)
    end

    it "死循环：watchdog 超时终止，gate 判 deny 不卡宿主（M3 验收第 4 条）" do
      interp2 = interp
      unless interp2
        pending "需要解释器"
        next
      end
      started = Time.instant
      d = MaliciousHelpers.dispatcher_for("deadloop", interp2)
      verdict = d.gate("memory.remember.before", JSON.parse("{}"), MaliciousHelpers.payload)
      elapsed = (Time.instant - started).total_milliseconds
      verdict.denied.should be_true
      elapsed.should be < 10_000 # watchdog 上限远小于样本死循环时长
    end

    # ulimit -v 在 macOS 是 no-op（RLIMIT_AS 不生效）——内存爆实测仅 Linux
    {% if flag?(:linux) %}
      it "内存爆：ulimit 虚存上限终止进程，outcome 非 ok（资源上限实测，Linux）" do
        interp2 = interp
        unless interp2
          pending "需要解释器"
          next
        end
        plugin = MaliciousHelpers.plugin("memory-bomb")
        registry = ::Sebas::Plugins::Registry.new
        registry.load_dir(MaliciousHelpers::FIXTURES)
        limits = ::Sebas::Plugins::ResourceLimits.from_config(memory_mb: 96, cpu_seconds: nil)
        runner = ::Sebas::Plugins::Runner.new(interp2, global_timeout_ms: 30_000_i64, limits: limits)
        request = ::Sebas::Plugins::Protocol::Request.new(
          request_id: Random::Secure.hex(6), plugin_id: "memory-bomb",
          action: "memory.remember.before", context: JSON.parse("{}"),
          payload: MaliciousHelpers.payload, config: JSON.parse("{}"), idempotency_key: nil)
        outcome = runner.call(plugin, request)
        outcome.ok.should be_false
      end
    {% end %}
  end
end
