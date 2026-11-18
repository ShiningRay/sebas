require "log"

module Sebas
  # 统一日志根（design.md §4.1）：所有子模块经 Log.for("sebas.<layer>") 派生
  Log = ::Log.for("sebas")
end
