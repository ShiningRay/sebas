# frozen_string_literal: true

# 前台接待（M4.3-WP3，Q8 拆分第一块）：匿名/临时会话包装——Session 藏而
# 不删（会话照常落 transcript，删除/生命周期归 M4.4）。
#
# 职责边界：routing binding 是渠道级接待，本层在其上做 agent 级包装——
# 无 binding 匹配的消息改投前台 agent（默认档 = 只读工具 + 转介建议），
# 原 fail-closed 审计保留（配置无前台 agent 时行为与 M0 一致）。
#
# 约定：config.agents["reception"] 存在即启用前台；会话键专用前缀
# "agent:reception:"（生命周期标记，M4.4 sessions 表承接）。
module Sebas
  module Agents
    module Reception
      FRONT_DESK_AGENT = "reception"

      # 前台默认档 = 当前会话只读 + 转介建议（无任何写副作用工具）。
      # 不含 memory.search（CWE-862，CodeRabbit）：全局记忆检索无 agent/
      # account/session 范围过滤——匿名会话可借此读取非公开记忆。带明确
      # 公开数据范围的接待检索工具留后续卡。
      READ_ONLY_TOOLS = %w[session.read]

      # 无 binding 消息的前台会话键：匿名/临时包装（peer 保留原始发件人
      # 便于转介）；结构与其余五段键一致（M4.4 sessions 表可按前缀识别）。
      def self.session_key_for(channel_type : String, account_id : String, peer : String) : String
        ::Sebas::Agents.session_key(FRONT_DESK_AGENT, account_id, channel_type, peer)
      end

      # 前台转介建议 system 片段：告知模型自身只读边界与转介职责——
      # 不能执行写操作，应建议用户明确目标后由人工配置 binding 转介。
      def self.referral_prompt : String
        "You are the front-desk reception agent. You have read-only access " \
        "(memory search and reading this conversation only). You cannot send " \
        "messages or modify anything. When the request needs write access or " \
        "a specialized agent, suggest which capability the user should ask " \
        "the operator to route (binding) to, and summarize what you found."
      end
    end
  end
end
