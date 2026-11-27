#!/usr/bin/env ruby
# frozen_string_literal: true

# 测试解释器 shim（M3-WP4，#16）：在 CRuby 上执行与真实沙箱完全相同的
# 合成程序（Prelude.compose 产物），用于本地与 CI spec 的确定性覆盖。
# 真实 mruby 解释器的验收在 mruby-sandbox workflow（沙箱裁剪 + e2e）。
#
# 通道契约与 mruby-sebas-stdio 一致：sebas_print（写 stdout + flush）、
# sebas_read（读一行 stdin，nil=EOF，去尾部换行）。
require "json"

def sebas_print(str)
  $stdout.write(str)
  $stdout.flush
end

def sebas_read
  line = $stdin.gets
  line ? line.chomp : nil
end

load ARGV[0]
