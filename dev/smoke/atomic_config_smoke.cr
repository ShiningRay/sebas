# EX-W1-03 前置冒烟 ①：Atomic(Config) 编译冒烟（design.md §15.1.8 消项）
# 目的：验证 reference type 作 Atomic(T) 泛型参数时各方法可用性，
#       消除 Atomic#swap 详注「T cannot contain any reference types」歧义。
class SmokeConfig
  getter name : String

  def initialize(@name : String = "initial")
  end
end

CONFIG = Atomic(SmokeConfig).new(SmokeConfig.new)
puts "get:        #{CONFIG.get.name}"
CONFIG.set(SmokeConfig.new("set"))
puts "set:        #{CONFIG.get.name}"
swapped = CONFIG.swap(SmokeConfig.new("swap"))
puts "swap:       #{swapped.name} -> #{CONFIG.get.name}"
prev, ok = CONFIG.compare_and_set(CONFIG.get, SmokeConfig.new("cas"))
puts "cas:        #{ok} #{prev.name} -> #{CONFIG.get.name}"
spawn(name: "reader") do
  3.times do
    cfg = CONFIG.get
    raise "nil snapshot" if cfg.nil?
    Fiber.yield
  end
end
Fiber.yield
puts "cross-fiber get: #{CONFIG.get.name}"
puts "ATOMIC_SMOKE_OK"
