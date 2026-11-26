require "spec"
require "../../../src/sebas"

module Sebas
  describe "CLI 日志绑定与 config 参数" do
    # 回归（gateway 启动即静默退出）：Log::Builder#matches 按整段前缀匹配，
    # 只绑 "sebas" 会丢弃全部 "sebas.<layer>" 子源——拒启原因与运行期日志全无输出。
    it "覆盖 sebas 根源与全部派生子源" do
      sources = [
        Platform::CLI::Log.source,
        Platform::CLI::Gateway::Log.source,
        Platform::Config::Loader::Log.source,
        Channels::Log.source,
      ]
      patterns = Platform::CLI::DEFAULT_LOG_SOURCES.split(',')
      sources.each do |source|
        source.starts_with?("sebas").should be_true
        # 子模块直接在 sebas 下派生，不得出现 sebas.sebas.* 双前缀
        source.should_not start_with("sebas.sebas.")
        patterns.any? { |pattern| ::Log::Builder.matches(source, pattern) }.should be_true
      end
    end

    it "config 参数缺值时报错退出，不静默回退默认 config.yaml" do
      Platform::CLI.run(["gateway", "-c"]).should eq(1)
      Platform::CLI.run(["gateway", "--config"]).should eq(1)
    end
  end
end
