# frozen_string_literal: true

module Sebas
  module Orchestration
    module Fork
      # 能力衰减（M4.2-WP1，fork-join-semantics.md §5 / Q6 裁断）：
      # 生效能力 = fork 显式声明 ∩ 父 tools.allow；未声明 tools 时用默认只读档
      # （§5.1：transcripts 窗口读取与 memory.search 有，message.send / memory.save
      # / 文件写 / 网络写等一切写副作用工具无，secrets 不随分身 §5.3，fork 工具无）。
      #
      # 白名单外声明不整体拒绝而是剔除并回执列明（§5.2「可观测，不静默失败」）；
      # 父 allow 含 "*" 视为全允许，声明全集生效。
      # L3 不可逆工具无论声明与否均叠加审批链（声明≠免审批，§7，审批链另包落地）。
      module Capability
        # §5.1 默认只读档：分身会话只读 + 共享记忆只读检索。
        DEFAULT_READ_ONLY = %w[memory.search session.read]

        record Grant,
          effective : Array(String),
          removed : Array(String)

        def self.resolve(declared : Array(String)?, parent_allow : Array(String)) : Grant
          return Grant.new(DEFAULT_READ_ONLY.dup, [] of String) if declared.nil?
          allow_all = parent_allow.includes?("*")
          effective = declared.select { |tool| allow_all || parent_allow.includes?(tool) }
          removed = declared.reject { |tool| allow_all || parent_allow.includes?(tool) }
          Grant.new(effective, removed)
        end
      end
    end
  end
end
