require "spec"
require "../../src/plugins/manifest"

def parse_manifest(text : String) : ::Sebas::Plugins::Manifest
  ::Sebas::Plugins::Manifest.parse(text)
end

# 断言 manifest 解析抛错并返回错误消息（收 JSON 字符串，避开多行块风格）
def manifest_error_of(json : String) : String
  ex = expect_raises(::Sebas::Plugins::ManifestError) do
    ::Sebas::Plugins::Manifest.parse(json)
  end
  ex.message.to_s
end

def manifest_json(**fields) : String
  {"schema_version" => 1}.merge(fields.to_h).to_json
end

module Sebas
  describe "plugin manifest（M3-WP4 fail-closed 校验）" do
    it "最小合法 manifest 解析成功，缺省字段给安全默认" do
      manifest = parse_manifest(manifest_json(id: "demo", version: "1.2.0", api_version: "1",
        actions: ["remember"]))
      manifest.id.should eq("demo")
      manifest.entrypoint.should be_nil
      manifest.tool_actions.should eq(["remember"])
      manifest.capabilities_list.should eq([] of String)
      manifest.hooks_list.should eq([] of String)
      manifest.declares_action?("remember").should be_true
      manifest.declares_capability?("memory_driver.write").should be_false
    end

    it "生命周期动作不进工具面（§12.3 无隐式 init）" do
      manifest = parse_manifest(manifest_json(id: "demo", version: "1.0.0", api_version: "1",
        actions: ["remember", "install", "enable", "disable"]))
      manifest.tool_actions.should eq(["remember"])
    end

    it "id 词法违规拒绝（大写/数字开头）" do
      manifest_error_of(manifest_json(id: "Demo", version: "1.0.0", api_version: "1"))
        .should contain("id must be lowercase")
      manifest_error_of(manifest_json(id: "0demo", version: "1.0.0", api_version: "1"))
        .should contain("id must be lowercase")
    end

    it "version 非 SemVer 拒绝" do
      manifest_error_of(manifest_json(id: "demo", version: "not-semver", api_version: "1"))
        .should contain("SemVer")
    end

    it "api_version 非数字 / 宿主不支持的主版本拒绝" do
      manifest_error_of(manifest_json(id: "demo", version: "1.0.0", api_version: "v1"))
        .should contain("major version number")
      manifest_error_of(manifest_json(id: "demo", version: "1.0.0", api_version: "2"))
        .should contain("unsupported plugin api_version 2")
    end

    it "钩子名必须命中 §12.11 闭集" do
      manifest_error_of(manifest_json(id: "demo", version: "1.0.0", api_version: "1",
        hooks: ["made.up.hook"]))
        .should contain("hook catalog")
      manifest = parse_manifest(manifest_json(id: "demo", version: "1.0.0", api_version: "1",
        hooks: ["memory.remember.before", "gateway.start"]))
      manifest.declares_hook?("gateway.start").should be_true
    end

    it "数组字段重复条目拒绝（报错不去重）" do
      manifest_error_of(manifest_json(id: "demo", version: "1.0.0", api_version: "1",
        actions: ["ping", "ping"]))
        .should contain("duplicates")
      manifest_error_of(manifest_json(id: "demo", version: "1.0.0", api_version: "1",
        capabilities: ["c", "c"]))
        .should contain("duplicates")
    end

    it "数组字段非法词法拒绝" do
      manifest_error_of(manifest_json(id: "demo", version: "1.0.0", api_version: "1",
        actions: ["has space"]))
        .should contain("actions[0]")
    end

    it "entrypoint 绝对路径 / 穿越拒绝" do
      manifest_error_of(manifest_json(id: "demo", version: "1.0.0", api_version: "1",
        entrypoint: "/etc/passwd.rb"))
        .should contain("relative path")
      manifest_error_of(manifest_json(id: "demo", version: "1.0.0", api_version: "1",
        entrypoint: "../lib/secret.rb"))
        .should contain("traverse")
      manifest_error_of(manifest_json(id: "demo", version: "1.0.0", api_version: "1",
        entrypoint: "plugin.sh"))
        .should contain(".rb script")
    end

    it "timeout_ms 越界 / config_schema 非对象拒绝" do
      manifest_error_of(manifest_json(id: "demo", version: "1.0.0", api_version: "1",
        timeout_ms: 0))
        .should contain("timeout_ms")
      manifest_error_of(manifest_json(id: "demo", version: "1.0.0", api_version: "1",
        timeout_ms: 999_999))
        .should contain("timeout_ms")
      manifest_error_of(%({"schema_version":1,"id":"demo","version":"1.0.0","api_version":"1","config_schema":[1,2]}))
        .should contain("config_schema")
    end

    it "manifest JSON 损坏给出可读错误" do
      manifest_error_of("{not json").should contain("invalid manifest JSON")
    end
  end
end
