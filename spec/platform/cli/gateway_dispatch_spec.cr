require "spec"
require "../../../src/platform/cli/gateway"

module Sebas
  describe "GatewayDispatch 拆分（#163）" do
    it "Gateway include GatewayDispatch，调度四方法归属 module" do
      # 拆分只改代码组织：四方法在 GatewayDispatch 定义、Gateway include 获得。
      # 若未来有人把方法挪回 gateway.cr 或 module 改名，此例立刻失败。
      # allocate 不做 initialize（无 store/IPC 副作用），is_a? 是编译期类型判断。
      gateway = ::Sebas::Platform::CLI::Gateway.allocate
      gateway.is_a?(::Sebas::Platform::CLI::GatewayDispatch).should be_true
    end

    it "gateway.cr 守住 400 行约定（拆分回归闸）" do
      # #163 的验收标准：行数反弹（方法挪回或新增膨胀）即失败。
      path = Path[__DIR__, "../../../src/platform/cli/gateway.cr"].normalize
      File.read_lines(path).size.should be <= 400
    end
  end
end
