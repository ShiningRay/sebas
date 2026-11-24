require "json"
require "socket"
require "./protocol"
require "../../log"

module Sebas
  module Admin
    module IPC
      # 管理命令处理器（M4.5-WP4 CodeRabbit 拆分）：admin_dispatch 族自
      # server.cr 迁入——连接生命周期（listen/handshake/帧循环）与管理命令
      # 职责分离；include mixin，实例变量由宿主 Server 提供（认证入口不变）。
      module AdminCommands
        Log = ::Sebas::Log.for("sebas.admin.ipc")

        private def authenticated_response(io : TCPSocket, frame : Frame, &block : Frame -> String) : String
          if caller_authenticated?(io)
            block.call(frame)
          else
            error_response(frame.id, "#{frame.type} requires an authenticated hello handshake")
          end
        end

        # ameba:disable Metrics/CyclomaticComplexity — 生命周期命令表分发，分支即命令本身
        private def lifecycle_dispatch(frame : Frame) : String
          lifecycle = @lifecycle_store
          return error_response(frame.id, "#{frame.type} not available: lifecycle 组件未装配") unless lifecycle

          data = frame.data
          case frame.type
          when "sessions.lifecycle"
            status = data["status"]?.try(&.as_s?)
            entries = lifecycle.list(status).map do |entry|
              JSON::Any.new({
                "session_key"    => JSON::Any.new(entry.session_key),
                "status"         => JSON::Any.new(entry.status),
                "last_active_at" => JSON::Any.new(entry.last_active_at),
              }.as(Hash(String, JSON::Any)))
            end
            ok_response(frame.id, {"sessions" => JSON::Any.new(entries)})
          when "sessions.dormant"
            days = 14
            if raw_days = data["older_than_days"]?
              parsed = raw_days.as_i?
              # 负数 → cutoff 落在未来全误标；越界/非整数不静默回退默认（CodeRabbit）
              return error_response(frame.id, "older_than_days must be a non-negative integer") if parsed.nil? || parsed < 0 || parsed > ::Sebas::Sessions::Lifecycle::MAX_DORMANT_DAYS
              days = parsed.to_i32
            end
            dormant = lifecycle.mark_dormant(days)
            ok_response(frame.id, {"dormant" => JSON::Any.new(dormant.map { |k| JSON::Any.new(k) })})
          when "sessions.archive"
            key = data["session_key"]?.try(&.as_s?)
            return error_response(frame.id, "session_key is required") unless key
            lifecycle.archive(key) ? ok_response(frame.id, {"archived" => JSON::Any.new(key)}) : error_response(frame.id, "session not found or already archived")
          when "sessions.gc"
            confirm = data["confirm"]?.try(&.as_bool?) || false
            cleaned = lifecycle.gc_archived(data["archive_dir"]?.try(&.as_s?) || "archived", confirm)
            ok_response(frame.id, {"collected" => JSON::Any.new(cleaned.to_i64)})
          else
            error_response(frame.id, "unknown lifecycle command")
          end
        end

        private def templates_dispatch(frame : Frame) : String
          templates = @template_registry
          return error_response(frame.id, "#{frame.type} not available: template registry 未装配") unless templates

          data = frame.data
          case frame.type
          when "templates.clone"
            template_id = data["template"]?.try(&.as_s?)
            new_id = data["new_id"]?.try(&.as_s?)
            patch = data["persona_patch"]?.try(&.as_s?)
            return error_response(frame.id, "template and new_id are required") unless template_id && new_id
            begin
              clone = templates.clone_from_template(template_id, new_id, patch)
              ok_response(frame.id, {"id" => JSON::Any.new(clone.id)})
            rescue ex : ::Sebas::Agents::RegistryError
              error_response(frame.id, ex.message.to_s)
            end
          else # templates.list
            ok_response(frame.id, {"templates" => JSON::Any.new(templates.disk_ids.map { |k| JSON::Any.new(k) })})
          end
        end

        # M4.4-WP4 管理面命令路由：approvals.*（既有）/sessions 生命周期/
        # templates（本卡新增）。写命令认证强制（CWE-863 同口径）；查询读

        private def admin_dispatch(io : TCPSocket, frame : Frame) : String
          frame_type = frame.type
          return error_response(frame.id, "missing frame type") unless frame_type
          needs_auth = frame_type != "approvals.pending" &&
                       frame.type != "sessions.lifecycle" && frame.type != "templates.list"
          if needs_auth && !caller_authenticated?(io)
            return error_response(frame.id, "#{frame.type} requires an authenticated hello handshake")
          end
          return error_response(frame.id, "missing frame type") if frame_type.nil?
          case frame_type
          when .starts_with?("approvals.")
            approvals_dispatch(io, frame)
          when "sessions.steer"
            steer_dispatch(frame)
          when .starts_with?("sessions.")
            lifecycle_dispatch(frame)
          else # templates.*
            templates_dispatch(frame)
          end
        end

        # busy steer 提交（M4.5-WP4）：明确 correction 语义入口——handler 由

        private def steer_dispatch(frame : Frame) : String
          handler = @steer_handler
          return error_response(frame.id, "sessions.steer not available: steer 中心未装配") unless handler
          session_key = frame.field("session_key").try(&.as_s?)
          payload = frame.field("payload").try(&.as_s?)
          return error_response(frame.id, "session_key and payload are required") unless session_key && payload
          # 显式指定但类型错误 → 可读错误（静默当未指定会错误绑定当前活跃 turn）
          given_turn = frame.field("target_turn_id")
          if given_turn && given_turn.as_s?.nil?
            return error_response(frame.id, "target_turn_id must be a string")
          end
          given_gen = frame.field("target_generation")
          if given_gen && given_gen.as_i64?.nil?
            return error_response(frame.id, "target_generation must be an integer")
          end
          target_turn_id = given_turn.try(&.as_s?)
          target_generation = given_gen.try(&.as_i64?)
          receipt = handler.call(session_key, payload, target_turn_id, target_generation)
          ok_response(frame.id, {
            "steer_id"   => JSON::Any.new(receipt.steer_id),
            "status"     => JSON::Any.new(receipt.status.to_s),
            "reason"     => JSON::Any.new(receipt.reason || ""),
            "turn_id"    => JSON::Any.new(receipt.target_turn_id),
            "generation" => JSON::Any.new(receipt.target_generation),
          })
        end

        # approvals 命令路由：approve/deny 是写操作（与 fork/join 同级认证，

        private def approvals_dispatch(io : TCPSocket, frame : Frame) : String
          needs_auth = frame.type != "approvals.pending"
          if needs_auth && !caller_authenticated?(io)
            return error_response(frame.id, "#{frame.type} requires an authenticated hello handshake")
          end
          frame.type == "approvals.pending" ? approvals_pending_response(frame) : approvals_response(frame)
        end

        # approvals.approve/deny：data.id 必带，data.by 可选；决策写 memo +

        private def approvals_response(frame : Frame) : String
          center = @approvals_center
          return error_response(frame.id, "#{frame.type} not available: approvals 组件未装配") unless center

          id = frame.data["id"]?.try(&.as_s?)
          return error_response(frame.id, "id is required") unless id
          by = frame.data["by"]?.try(&.as_s?) || "operator"
          ok = frame.type == "approvals.approve" ? center.approve(id, by) : center.deny(id, by)
          ok ? ok_response(frame.id, {"id"       => JSON::Any.new(id),
                                      "decision" => JSON::Any.new(frame.type == "approvals.approve" ? "approved" : "denied")}) : error_response(frame.id, "no pending approval #{id}")
        end

        private def approvals_pending_response(frame : Frame) : String
          center = @approvals_center
          return error_response(frame.id, "approvals.pending not available: approvals 组件未装配") unless center

          items = center.pending_requests.map do |req|
            JSON::Any.new({
              "id"       => JSON::Any.new(req.id),
              "tool"     => JSON::Any.new(req.tool),
              "args"     => JSON::Any.new(req.args_summary),
              "run_id"   => JSON::Any.new(req.run_id),
              "deadline" => JSON::Any.new(req.deadline.to_rfc3339),
            }.as(Hash(String, JSON::Any)))
          end
          ok_response(frame.id, {"pending" => JSON::Any.new(items)})
        end

        private def fork_join_response(frame : Frame) : String
          handler = @fork_handler
          return error_response(frame.id, "#{frame.type} not available: fork 组件未装配") unless handler

          begin
            result = handler.call(JSON::Any.new(frame.data))
            ok_response(frame.id, {"result" => result})
          rescue ex : ::Sebas::Platform::Store::StoreError
            # 校验异常（缺 task / 缺 main agent 配置）转错误响应——保留连接，
            # 客户端拿到该请求的失败原因而非断连（CodeRabbit）
            error_response(frame.id, ex.message.to_s)
          end
        end

        # 注册 fork/join 命令处理器（gateway 装配后接线；handler 收 IPC 帧数据

        private def runs_response(frame : Frame) : String
          if frame.type == "runs.list"
            runs = @runs_view.try(&.list) || [] of JSON::Any
            return ok_response(frame.id, {"runs" => JSON::Any.new(runs)})
          end
          run_id = frame.field("run_id").try(&.as_s?) || ""
          result = @runs_view.try(&.get(run_id))
          result ? ok_response(frame.id, result) : error_response(frame.id, "run not found")
        end

        private def ok_response(id : String?, payload : Hash(String, JSON::Any)) : String
          IPC.ok(id, payload)
        end

        private def error_response(id : String?, message : String) : String
          IPC.error(id, message)
        end
      end
    end
  end
end
