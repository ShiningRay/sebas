require "spec"
require "../src/sebas"

describe Sebas do
  it "declares a semantic version" do
    Sebas::VERSION.should match(/^\d+\.\d+\.\d+$/)
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
