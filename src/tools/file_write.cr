# frozen_string_literal: true

require "json"
require "digest"

module Sebas
  module Tools
    # 最小文件写工具（M4.2-WP2）：side_effect=FileWrite 的示例实现——
    # 副作用四级里 L1 的具体归属（semantics §2.1「工具映射在落地时定案」）。
    # 写即事实：join 侧不回滚，经 EffectsLedger 列明 + 指纹冲突检测进父裁决
    # 清单（semantics §2.2 L1 行「不自动 merge」）。
    class FileWriteTool < Tool
      # base_dir 工作区（M4.3-WP1 CodeRabbit，CWE-73）：解析后的绝对路径必须
      # 落在 base_dir 内——模型给的相对路径在 base_dir 下解析，绝对/上跳路径
      # 逃出工作区即拒绝。默认进程 cwd；fork/测试场景可指定隔离工作区。
      def initialize(@base_dir : String = Dir.current)
        super("file.write", "Write content to a local file path (relative to the workspace, overwrites)",
          ReplaySemantics::Effectful, Risk::Medium, SideEffect::FileWrite)
      end

      def run(args : JSON::Any, ctx : ToolContext) : ToolResult
        path = args["path"]?.try(&.as_s?)
        content = args["content"]?.try(&.as_s?)
        return ToolResult.error("path/content are required") unless path && content
        resolved = File.expand_path(path, @base_dir)
        unless resolved.starts_with?(@base_dir)
          return ToolResult.error("path escapes the workspace (#{path})")
        end
        # post 摘要取自实际写入字节（非写后重读，防并发改动污染）；写前现状
        # 摘要由 Executor 在执行前统一入账（pre 基线，判「父在成员写前已动过」）。
        File.write(resolved, content)
        ToolResult.success("wrote #{content.size} bytes to #{path}",
          digest: ::Digest::SHA256.hexdigest(content))
      rescue ex : ::Exception
        ToolResult.error("file write failed: #{ex.message}")
      end
    end
  end
end
