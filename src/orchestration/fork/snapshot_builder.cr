# frozen_string_literal: true

module Sebas
  module Orchestration
    module Fork
      # fork 快照组装器（M4.1-WP3）：父会话上下文的只读拷贝 → HttpProvider
      # 纯消息数组（providers.cr:58-88 接口）。
      #
      # 快照三部分（semantics §1.2）：①transcripts 窗口（父会话最近 window 行）；
      # ②父 agent persona（system prompt）；③skills 注入渲染文本。
      # 边界（快照不含）：父 secrets（api_key 等 §5.3）、父在途消息（只读已落库
      # transcripts 天然一致）、其他会话 transcript（五段键分片隔离）。
      #
      # 纯函数化：输入全部显式传入，输出消息数组——便于 spec 断言。
      # 父会话键由调用方（M4.1-WP5 触发面）传入，本模块不猜测路由。
      module SnapshotBuilder
        DEFAULT_WINDOW = 50

        record Input,
          task : String,
          count : Int32,
          window : Int32?,
          include : Array(String)?,
          tools : Array(String)?,
          role : String?,
          mode : String,
          deadline : Int32

        # 组装单个分身的消息数组。member_index 从 1 起。
        # frozen_transcripts：调用方在首成员执行前读好的固定窗口（全成员同源）。
        # include 白名单（semantics §1.2）：缺省 ["transcripts","system_prompt","skills"]；
        # 逐项控制注入面——白名单不含 secrets 项（§5.3）。
        def self.build(frozen_transcripts : Array(::Sebas::Platform::Store::TranscriptRow),
                       parent_persona : String, skills_text : String,
                       input : Input, member_index : Int) : Array(Providers::Message)
          includes = input.include || %w[transcripts system_prompt skills]
          messages = [] of Providers::Message
          system = String.build do |io|
            io << parent_persona if includes.includes?("system_prompt")
            io << "\n\n" << skills_text if includes.includes?("skills") && !skills_text.empty?
            role_note = input.role ? " Role card: #{input.role}." : ""
            io << "\n\n[You are fork member #{member_index} of #{input.count} for this task. "
            io << "You run with forked capability set; irreversible actions require approval.#{role_note}]"
          end
          messages << Providers::Message.new("system", system)
          if includes.includes?("transcripts")
            window = input.window || DEFAULT_WINDOW
            frozen_transcripts.last(window).each do |row|
              # 存储角色 agent → provider 角色 assistant（gateway.agent_turn 同款转换）
              role = row.role == "agent" ? "assistant" : row.role
              messages << Providers::Message.new(role, row.content)
            end
          end
          # 任务描述兜底为 user 消息（父会话无 transcripts 时任务仍可执行）
          messages << Providers::Message.new("user", input.task)
          messages
        end
      end
    end
  end
end
