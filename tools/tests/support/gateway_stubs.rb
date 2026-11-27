# frozen_string_literal: true

# GithubGateway 的假 runner。
#
# 生产 runner 的契约是 json!(*argv) 返回已解析的 Hash/Array。四个测试文件
# 各自内联了「按顺序吐响应」的 StubRunner/SeqRunner，外加一份要记录 argv 的
# 变体；这里收成一处，签名差异用构造参数表达。
require "json"

module GatewayStubs
  # 按调用顺序返回预置响应。响应可为 JSON 字符串或已解析对象。
  class SequenceRunner
    attr_reader :argvs

    def initialize(*responses)
      @responses = responses.flatten
      @argvs = []
    end

    def json!(*argv)
      @argvs << argv
      shift
    end

    # 不让「响应耗尽」变成静默 nil：那会让生产代码把缺页当空页放行。
    def shift
      raise "SequenceRunner 响应已耗尽（已消费 #{@argvs.length} 次）" if @responses.empty?

      value = @responses.shift
      value.is_a?(String) ? JSON.parse(value) : value
    end
  end
end
