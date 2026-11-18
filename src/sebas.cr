# Sebas 根 require：按 design.md §13 目录结构装载各层模块
require "./version"
require "./log"

require "./platform/**"
require "./channels/**"
require "./routing/**"
require "./agents/**"
require "./orchestration/**"
require "./tools/**"
require "./providers/**"
require "./admin/**"
require "./plugins/**"
