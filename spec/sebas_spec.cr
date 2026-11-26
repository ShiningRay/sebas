require "spec"
require "../src/sebas"

describe Sebas do
  it "declares a semantic version" do
    Sebas::VERSION.should match(/^\d+\.\d+\.\d+$/)
  end

  # 构建期注入：仓库内构建解析 `.git` 的 HEAD 取前 12 位（不调用 git，见 src/version.cr）；
  # 读不到时退化为 "unknown"，构建不因此中断。
  it "records the git revision of the build" do
    Sebas::GIT_REV.should_not be_empty
    # 12 位短哈希，或环境注入的其他写法，或 unknown；带引号/空白说明宏取值写错
    Sebas::GIT_REV.should match(/\A[0-9A-Za-z._\-]+\z/)
    Sebas::GIT_REV.size.should be <= 40
  end

  # 未注入 SEBAS_BUILD_REV 时构建读 .git 并与 HEAD 对齐；注入是受支持的构建方式
  # （源码包 / 受控构建），此时 rev 跟仓库 HEAD 无关，只校验裁剪规则。
  it "resolves the revision from .git or from the SEBAS_BUILD_REV override" do
    override = ENV["SEBAS_BUILD_REV"]?.to_s.strip
    if override.empty?
      unless Sebas::GIT_REV == "unknown" # 无 .git 的源码包里允许 unknown
        head = `git -C "#{__DIR__}/.." rev-parse HEAD`.strip
        Sebas::GIT_REV.should eq(head[0..11]) unless head.empty?
      end
    else
      expected = override.size == 40 ? override[0..11] : override
      Sebas::GIT_REV.should eq(expected)
    end
  end

  it "renders version and git revision as one line" do
    Sebas.version_string.should eq("#{Sebas::VERSION} (#{Sebas::GIT_REV})")
  end

  it "namespaces the design.md §13 layers" do
    Sebas::Platform::Store.should_not be_nil
    Sebas::Channels.should_not be_nil
    Sebas::Routing.should_not be_nil
    Sebas::Agents.should_not be_nil
    Sebas::Orchestration.should_not be_nil
    Sebas::Tools.should_not be_nil
    Sebas::Providers.should_not be_nil
    Sebas::Admin.should_not be_nil
    Sebas::Plugins.should_not be_nil
  end

  it "derives per-layer log sources" do
    Sebas::Log.for("config").source.should eq("sebas.config")
  end
end
