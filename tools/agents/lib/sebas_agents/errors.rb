# frozen_string_literal: true

module SebasAgents
  # 所有可预期错误的基类。CLI 捕获后输出结构化错误并返回非零退出码。
  class Error < StandardError; end

  # 元数据、依赖或认领状态冲突。按流程约定 fail-closed，不猜下一张卡。
  class InvalidPlan < Error; end

  # gh / git 调用失败。错误必须原样保留，不转换成空列表。
  class CommandError < Error
    attr_reader :command, :stderr

    def initialize(message, command: nil, stderr: nil)
      super(message)
      @command = command
      @stderr = stderr
    end
  end

  # 命令参数或输入文件不符合契约。
  class UsageError < Error; end
end
