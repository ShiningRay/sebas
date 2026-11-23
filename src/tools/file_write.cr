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
      # base_dir 工作区（M4.3-WP1 CodeRabbit，CWE-73/61/22）：解析后的绝对路径
      # 必须落在 base_dir realpath 内——模型给的相对路径在 base_dir 下解析，
      # 绝对/上跳/符号链接逃逸路径即拒绝。默认进程 cwd；fork/测试场景可指定
      # 隔离工作区。
      def initialize(@base_dir : String = Dir.current)
        super("file.write", "Write content to a local file path (relative to the workspace, overwrites)",
          ReplaySemantics::Effectful, Risk::Medium, SideEffect::FileWrite)
      end

      # 自记账（M4.3-WP1 CodeRabbit）：实际写入路径只有本工具知道（相对 path
      # 在 base_dir 下解析）——pre/post 摘要与 target 由工具直接入账，
      # Executor 的通用记账对本工具跳过（防错路径摘要）。
      def self_records_effects? : Bool
        true
      end

      def run(args : JSON::Any, ctx : ToolContext) : ToolResult
        path = args["path"]?.try(&.as_s?)
        content = args["content"]?.try(&.as_s?)
        return ToolResult.error("path/content are required") unless path && content
        # ①语法层：拒相对上跳 / UNC（\\\\ 开头）/ 盘符
        unless valid_relative_path?(path)
          return ToolResult.error("path must be a relative path without '..' or UNC/drive letters")
        end
        # ②解析层：expand_path 后必须仍在 base_dir 内
        resolved = File.expand_path(path, @base_dir)
        unless resolved.starts_with?(@base_dir)
          return ToolResult.error("path escapes the workspace (#{path})")
        end
        # ③链接层：父目录 realpath（解析 symlink 后）必须仍在 base_dir realpath 内
        real_base = File.realpath(@base_dir)
        real_parent = begin
          File.realpath(File.dirname(resolved))
        rescue ex : ::Exception
          return ToolResult.error("path parent unresolvable: #{ex.message}")
        end
        unless real_parent.starts_with?(real_base)
          return ToolResult.error("path escapes the workspace through symlinks (#{path})")
        end

        # 双基线摘要由本工具采集（实际写入路径只有本工具知道）：pre = 写前
        # resolved 现状三态（digest/deleted）；post = 实际写入字节摘要（非写后
        # 重读，防并发改动污染）。台账 target 记 resolved 绝对路径。
        pre_digest = File.file?(resolved) ? ::Digest::SHA256.hexdigest(File.read(resolved)) : "deleted"
        File.write(resolved, content)
        post_digest = ::Digest::SHA256.hexdigest(content)
        ctx.ledger.try(&.record("file.write", SideEffect::FileWrite, resolved, post_digest, pre_digest))
        ToolResult.success("wrote #{content.size} bytes to #{path}", digest: post_digest)
      rescue ex : ::Exception
        ToolResult.error("file write failed: #{ex.message}")
      end

      # 路径合法性：拒 UNC / 盘符 / 上跳段；POSIX 绝对路径允许——解析层
      # （expand_path + starts_with base_dir）已把它限制在工作区内
      private def valid_relative_path?(path : String) : Bool
        return false if path.starts_with?("\\") # UNC
        return false if path =~ /^[a-zA-Z]:/    # Windows 盘符（C:/ 或 C:\）
        return false if path.includes?("../")
        return false if path.includes?(".." + ::File::SEPARATOR)
        return false if path == ".."
        true
      end
    end
  end
end
