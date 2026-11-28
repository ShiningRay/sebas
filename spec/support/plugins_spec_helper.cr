require "json"
require "process"
require "../../src/plugins/manifest"
require "../../src/plugins/protocol"
require "../../src/plugins/prelude"
require "../../src/plugins/registry"
require "../../src/plugins/runner"
require "../../src/plugins/dispatch"
require "../../src/plugins/tool"
require "../../src/tools/executor"
require "../../src/platform/store/store"

# 插件 spec 支撑（M3-WP4，#16）：解释器可注入——SEBAS_PLUGIN_INTERPRETER
# 指向真实裁剪 mruby（沙箱 e2e 口径），缺省回退 CRuby shim（合成程序完全
# 相同，协议/DSL 语义确定性覆盖）。两者都没有则 runner spec 按平台限制
# pending（真实验收以 mruby-sandbox workflow 为准）。
module PluginSpecSupport
  SPEC_DIR     = Path[__DIR__, "..", "plugins"].normalize
  FIXTURES     = SPEC_DIR / "fixtures"
  SHIM         = Path[__DIR__, "stub_interpreter.rb"].normalize
  EXAMPLES_DIR = Path[__DIR__, "..", "..", "examples", "plugins"].normalize

  def self.interpreter : Array(String)?
    if env = ENV["SEBAS_PLUGIN_INTERPRETER"]?
      return [env]
    end
    ruby = Process.find_executable("ruby")
    [ruby, SHIM.to_s] if ruby
  end

  def self.make_runner(interpreter : Array(String)) : ::Sebas::Plugins::Runner
    runner = ::Sebas::Plugins::Runner.new(interpreter, global_timeout_ms: 5_000_i64)
    runner.capability_handler = ->(_plugin : ::Sebas::Plugins::LoadedPlugin, capability : String, params : JSON::Any, _replay_key : String?) do
      case capability
      when "test.echo"
        params
      when "test.fail"
        raise ::Exception.new("driver exploded")
      when "memory_driver.write"
        JSON::Any.new({"id" => JSON::Any.new("mem-1"), "kind" => JSON::Any.new("memory")} of String => JSON::Any)
      else
        JSON::Any.new(nil)
      end
    end
    runner
  end

  # 夹具注册表 + 派发服务（夹具必须全部合法——单份坏 manifest 的容错
  # 在 registry_spec 用临时目录单独验证）
  def self.make_dispatch(interpreter : Array(String)) : ::Sebas::Plugins::Dispatch
    registry = ::Sebas::Plugins::Registry.new
    report = registry.load_dir(FIXTURES)
    report.errors.each { |e| fail("fixture load error: #{e}") }
    dispatch = ::Sebas::Plugins::Dispatch.new(registry, make_runner(interpreter))
    dispatch
  end

  def self.request(action : String, payload : JSON::Any? = nil) : ::Sebas::Plugins::Protocol::Request
    ::Sebas::Plugins::Protocol::Request.new(
      request_id: Random::Secure.hex(6),
      plugin_id: "spec",
      action: action,
      context: JSON.parse("{}"),
      payload: payload || JSON.parse("{}"),
      config: JSON.parse("{}"),
      idempotency_key: nil,
    )
  end

  def self.spec_store : ::Sebas::Platform::Store::Store
    dir = Path[Dir.tempdir, "sebas-plugin-spec", Random::Secure.hex(4)]
    ::Sebas::Platform::Store::Store.new(dir / "sebas.db")
  end
end
