# frozen_string_literal: true

# CLI 调用的共用夹具。
#
# 三个测试文件各自定义过一份 run_cli / with_snapshot，签名一致、只差缩进；
# 复制多份的结果是「改一处忘一处」——比如把 out 换成 err 时漏改某个副本，
# 断言就会读到空串照常通过。
require "json"
require "stringio"
require "tmpdir"

module CliHelpers
  # 返回 [退出码, stdout, stderr]，与 CLI#run 的契约对齐。
  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = SebasAgents::CLI.new(out: out, err: err).run(argv)
    [status, out.string, err.string]
  end

  # 把快照写进临时目录再交给 CLI；yield 拿到 [path, dir]。
  def with_snapshot(data)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      File.write(path, JSON.generate(data), encoding: "UTF-8")
      yield path, dir
    end
  end

  def write_json(dir, name, data)
    path = File.join(dir, name)
    File.write(path, JSON.generate(data), encoding: "UTF-8")
    path
  end
end
