require "spec"
require "../../../src/sebas"

module Sebas
  # 捕获 CLI 日志输出：日志后端默认写 STDERR，测试期间换成内存 IO 才能断言文案。
  # `CLI.run` 在 setup_logging 里把当时的 log_io 注册为全局后端，因此恢复时必须
  # 重新执行一次绑定（reset_logging），否则后续测试的日志会写进没人读的
  # IO::Memory，诊断输出丢失。
  def self.capture_cli_log(&) : String
    original = Platform::CLI.log_io
    io = IO::Memory.new
    Platform::CLI.log_io = io
    begin
      yield
    ensure
      Platform::CLI.log_io = original
      Platform::CLI.reset_logging
    end
    io.to_s
  end

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

    # 只断言退出码不足以区分「缺值报错」与「回退默认配置后没找到文件」，
    # 必须核对诊断文案。
    it "config 参数缺值时报出 requires a value，不静默回退默认 config.yaml" do
      {"-c", "--config"}.each do |flag|
        log = Sebas.capture_cli_log { Platform::CLI.run(["gateway", flag]).should eq(1) }
        log.should contain("option #{flag} requires a value")
      end
    end

    # `--config valid.yaml -c`：先命中的别名不得掩盖后一个缺值选项
    it "先命中合法别名也不放过后续缺值选项" do
      path = Path[Dir.tempdir, "sebas-cli-spec-#{Random::Secure.hex(4)}.yaml"]
      File.write(path, "agents:\n  main:\n    model: m\n")
      begin
        log = Sebas.capture_cli_log do
          Platform::CLI.run(["gateway", "--config", path.to_s, "-c"]).should eq(1)
        end
        log.should contain("option -c requires a value")
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end
end
