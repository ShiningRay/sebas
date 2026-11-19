require "json"
require "../agents/agents"
require "../platform/store/store"
require "./pool"
require "../log"

# subagent（M3-WP3，design.md §8.2/§8.3，Pi ownership 模式）：
# 被拥有的会话/任务（owner_task_id 找回——store tasks 列 day one 就位）；
# 受限工具集（剔除 message/spawn 社交工具）；命名信号量并发上限（默认 3，§8.3）；
# 崩溃后经 owner_task_id 找回同一子任务（§14 M3 验收）。
module Sebas
  module Agents
    class SubagentManager
      Log = Sebas::Log.for("sebas.agents.subagent")

      DEFAULT_MAX_CONCURRENT = 3

      getter semaphore : Semaphore
      getter max_concurrent : Int32

      def initialize(@store : ::Sebas::Platform::Store::Store,
                     @registry : AgentRegistry,
                     @executor : -> Tools::ToolResult, # subagent turn 执行体（受限工具面由调用方组装）
                     max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT)
        @semaphore = Semaphore.new(max_concurrent)
        @max_concurrent = max_concurrent
      end

      # 派发子任务：owner_task_id 找回锚点（Pi ownership）——同 subtask_key 的子任务
      # 若已存在（上次崩溃遗留 interrupted）则**找回同一 task**而非新建。
      def spawn_subtask(owner_task_id : String, subtask_key : String, agent_id : String,
                        prompt : String, parent_session : String) : String
        task_id = "sub:#{subtask_key}"
        existing_status = @store.task_status?(task_id)

        if existing_status == "interrupted"
          Log.info { "subtask recovered: #{task_id} (owner=#{owner_task_id})" }
          @store.resume_task(task_id)
        else
          @store.create_task(task_id, "subtask", parent_id: owner_task_id,
            owner_task_id: owner_task_id, payload: %({"agent": "#{agent_id}", "prompt": #{prompt.inspect}}))
          @registry.get_or_create(agent_id) # 确保目录/persona 就位
          @store.append_transcript(
            ::Sebas::Agents.session_key(agent_id, "internal", "subagent", subtask_key),
            "user", prompt
          )
        end

        spawn(name: "sebas-subtask:#{task_id}") do
          @semaphore.acquire # 并发上限（超限排队，不失控）
          begin
            result = @executor.call
            if result.ok?
              @store.complete_task(task_id, result.output)
              @store.append_transcript(
                ::Sebas::Agents.session_key(agent_id, "internal", "subagent", subtask_key),
                "agent", result.output
              )
            else
              @store.fail_task(task_id, result.error)
            end
          rescue ex : ::Exception
            Log.error(exception: ex) { "subtask #{task_id} crashed (left interrupted for recovery)" }
          ensure
            @semaphore.release
          end
        end
        task_id
      end

      # 找回：owner 的全部子任务（崩溃恢复口径——ownerTaskId 锚点）
      def subtasks_of(owner_task_id : String) : Array(::Sebas::Platform::Store::TaskRow)
        @store.tasks_by_owner(owner_task_id)
      end
    end
  end
end
