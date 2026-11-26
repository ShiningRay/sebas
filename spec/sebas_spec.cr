require "spec"
require "../src/sebas"

describe Sebas do
  it "declares a semantic version" do
    Sebas::VERSION.should match(/^\d+\.\d+\.\d+$/)
  end

  # 构建期注入：仓库内构建取 `git rev-parse --short=12 HEAD`，
  # 无 .git 且未设 SEBAS_BUILD_REV 时退化为 "unknown"。
  it "records the git revision of the build" do
    Sebas::GIT_REV.should_not be_empty
    # 形如 12 位短哈希，或环境注入的其他写法；带引号/空白说明宏取值写错
    Sebas::GIT_REV.should match(/\A[0-9A-Za-z._\-]+\z/)
    Sebas::GIT_REV.size.should be <= 40
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
