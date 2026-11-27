# frozen_string_literal: true

# PathChecks 的构造与执行夹具。
#
# 四个 PathChecks 测试类（基础、Round2、Round3、集成）各自复制过一份
# change/run_check，签名一致；一旦 VerificationReport 的构造方式变化，
# 四份都得改，漏一份就会出现「某个类还在用旧姿势」的假绿。
module PathChecksHelpers
  def change(path, patch)
    SebasAgents::PathChecks::Change.new(path: path, patch: patch)
  end

  def run_check(changes, body: "", threads: [])
    report = SebasAgents::VerificationReport.new
    SebasAgents::PathChecks.check(changes: changes, body: body, threads: threads, report: report)
    report
  end
end
