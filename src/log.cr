require "log"

module Sebas
  # 统一日志根（design.md §4.1）：所有子模块一律经实例方法 `Sebas::Log.for("<layer>")`
  # 派生为 "sebas.<layer>"（父源前缀由 Log#for 自动拼接）。不要再手写 "sebas." 前缀——
  # 那会得到 "sebas.sebas.<layer>"，被日志绑定按整段前缀匹配时静默丢弃。
  Log = ::Log.for("sebas")
end
