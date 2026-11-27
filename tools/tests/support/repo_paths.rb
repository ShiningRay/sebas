# frozen_string_literal: true

# tools 测试共用的仓库路径。support/ 位于 tools/tests/support/，
# 距仓库根三级——旧测试散落在 tools/ 下时每个文件各写一遍
# File.expand_path("..", __dir__)，路径基准随文件移动就会静默错位。
module RepoPaths
  ROOT = File.expand_path("../../..", __dir__)
  TOOLS_DIR = File.join(ROOT, "tools")
  AGENTS_LIB = File.join(TOOLS_DIR, "agents", "lib")
  DOCS_DIR = File.join(ROOT, "docs")

  module_function

  # RepoPaths.join("docs", "x.md") —— 避免每处重复 File.join(ROOT, ...)。
  def join(*parts)
    File.join(ROOT, *parts)
  end
end
