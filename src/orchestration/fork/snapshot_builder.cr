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
        def self.build(store : ::Sebas::Platform::Store::Store,
                       parent_session_key : String,
                       parent_persona : String, skills_text : String,
                       input : Input, member_index : Int,
                       default_window : Int32 = DEFAULT_WINDOW) : Array(Providers::Message)
          messages = [] of Providers::Message
          # system prompt = 父 persona + skills 注入 + 分身身份行
          system = String.build do |io|
            io << parent_persona
            io << "\n\n" << skills_text unless skills_text.empty?
            io << "\n\n[You are fork member #{member_index} of #{input.count} for this task. "
            io << "You run with forked capability set; irreversible actions require approval.]"
          end
          messages << Providers::Message.new("system", system)
          # transcripts 窗口：只读已落库（在途消息天然不在）；include 白名单缺省
          # ["transcripts","system_prompt","skills"]——本版三项恒注入（无 secrets 项可选）。
          window = input.window || default_window
          store.transcripts(parent_session_key).last(window).each do |row|
            messages << Providers::Message.new(row.role, row.content)
          end
          # 任务描述兜底为 user 消息（父会话无 transcripts 时任务仍可执行）
          messages << Providers::Message.new("user", input.task)
          messages
        end
      end
    end
  end
end
