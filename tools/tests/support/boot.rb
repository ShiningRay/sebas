# frozen_string_literal: true

# tools 测试的统一装载点。
#
# 以前每个测试文件都要在 Makefile、ci.yml 的 docs job、ci.yml 的 verify job
# 里各登记一次，新增一个文件得改三处，漏一处就静默不跑。现在只在这里
# require 一次，或者直接 `ruby tools/tests/run.rb` 全量跑。
#
# 注意：本文件不是测试，不含断言；只负责准备标准库依赖与共用的夹具，
# 让各测试文件不必重复罗列 require。
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require "shellwords"
require "yaml"

require_relative "repo_paths"
require_relative "snapshot_helpers"
require_relative "cli_helpers"
require_relative "gateway_stubs"
require_relative "path_checks_helpers"
