require "digest/sha1"
require "json"
require "../../log"

# 审批节点（M2-WP4，design.md §7.5）：
# pending → approved / denied / timeout；超时即拒（fail-closed，默认 300s，注入时钟可测）；
# 无人值守（cron/webhook/事件触发）默认 deny；hardline blocklist 在一切模式之上不可 override；
# 审批模式 manual/smart/off；决策 memo first-write-wins（§7.3 决策级）。
module Sebas
  module Orchestration
    module Approvals
      # 注入时钟（§14 M2 验收第 2 条：注入时钟快进实测超时 deny）
      @@clock : -> Time = -> { Time.utc }

      def self.clock=(proc : -> Time) : Nil
        @@clock = proc
      end

      def self.now : Time
        @@clock.call
      end

      record Request, id : String, tool : String, args_summary : String,
        run_id : String, unattended : Bool, mode : String, deadline : Time, created_at : Time
      record Decision, approved : Bool, reason : String

      class Center
        Log = Sebas::Log.for("sebas.approvals")

        DEFAULT_TIMEOUT = 300

        # hardline blocklist（§7.5 不可 override 的地板；Hermes 层 2 口径）
        HARDLINE_PATTERNS = [
          "rm -rf /", "rm -fr /", "rm -rf /*", "rm -rf ~", "rm -rf .",
          "mkfs", "format c:", "format-volume", "format-volume -driveletter c",
          "rd /s /q c:\\", "del /f /s /q c:\\", "shutdown", "restart-computer",
          "stop-computer", "fork bomb", ":(){ :|:& };:",
        ]

        @pending = Hash(String, Request).new
        @mutex = Mutex.new
        @store : ::Sebas::Platform::Store::Store?
        @channel : Channel(String)?

        def initialize(@store : ::Sebas::Platform::Store::Store? = nil)
        end

        # 请求审批：返回 Decision。规则顺序（fail-closed）：
        # hardline deny > mode off（放行）> 无人值守 deny > 已有 memo 决策 > 超时 deny > 等待人工
        def request(tool : String, args_summary : String, run_id : String,
                    unattended : Bool, mode : String,
                    timeout_seconds : Int32 = DEFAULT_TIMEOUT) : Decision
          # ① hardline：不可 override（在一切模式之上仍拒绝）
          if hardline?(tool, args_summary)
            return Decision.new(false, "hardline blocklist: command is forbidden regardless of approval mode")
          end

          # ② off 模式放行（hardline 之上仍拒绝）
          return Decision.new(true, "mode=off") if mode == "off"

          # ③ 无人值守默认 deny（Hermes 三键口径；smart 辅助评风险在本平台=v1 按保守 deny）
          if unattended
            return Decision.new(false, "unattended run: dangerous action denied by default")
          end

          request_id = "approval:#{run_id}:#{tool}:#{::Digest::SHA1.hexdigest(args_summary)}"
          # 决策级 memo first-write-wins：重放读已存答案不重复决策（§7.3）
          memo = @store.try(&.memo_get(memo_key(request_id)))
          if memo
            return Decision.new(memo.starts_with?("approved"), "memo: #{memo}")
          end

          deadline = Approvals.now + timeout_seconds.seconds
          request = Request.new(request_id, tool, args_summary, run_id, unattended, mode, deadline, Approvals.now)
          @mutex.synchronize { @pending[request_id] = request }
          Log.info { "approval requested: #{tool} (run=#{run_id} deadline=#{deadline})" }

          # 等待人工决定直到 deadline；超时 deny（fail-closed）
          wait_decision = wait_for_decision(request_id, deadline)
          decision = wait_decision || begin
            Log.warn { "approval timeout -> deny (fail-closed): #{request_id}" }
            Decision.new(false, "timeout deny (fail-closed)")
          end
          @mutex.synchronize { @pending.delete(request_id) }
          record_decision(memo_key(request_id), decision)
          decision
        end

        # 人工双入口 API（TUI/HTTP 共用语义，§9.2 approvals.approve/deny）：
        # 写决策 memo + 移除 pending；等待中的 request 轮询到 memo 即返回
        def approve(id : String, by : String = "operator") : Bool
          decide(id, Decision.new(true, "approved by #{by}"))
        end

        def deny(id : String, by : String = "operator") : Bool
          decide(id, Decision.new(false, "denied by #{by}"))
        end

        def pending_requests : Array(Request)
          @mutex.synchronize { @pending.values }
        end

        private def hardline?(tool : String, args_summary : String) : Bool
          haystack = (tool + " " + args_summary).downcase
          HARDLINE_PATTERNS.any? { |pattern| haystack.includes?(pattern) }
        end

        private def memo_key(request_id : String) : String
          "decision:#{request_id}"
        end

        private def record_decision(key : String, decision : Decision) : Nil
          @store.try(&.memo_put(key, decision.reason)) # reason 即审计痕迹（approved by …/denied by …）
        end

        private def decide(id : String, decision : Decision) : Bool
          request = nil
          removed = @mutex.synchronize do
            request = @pending.delete(id)
            !request.nil?
          end
          return false unless removed
          # 超时后的批准不得生效（CodeRabbit）：wait 侧超时 deny 与人工
          # approve 存在竞态窗口——deadline 已过即拒绝该决策（pending 已移除，
          # 操作员从 false 返回值感知「已过期」），不写 memo 防过期决策固化。
          if request.try(&.deadline).try { |deadline| Approvals.now >= deadline }
            Log.warn { "approval decided after deadline, rejected: #{id}" }
            return false
          end
          record_decision(memo_key(id), decision)
          Log.info { "approval decided: #{id} -> #{decision.reason}" }
          true
        end

        # 等待人工决定：轮询决策 memo；deadline 后返回 nil（调用方 deny fail-closed）
        private def wait_for_decision(request_id : String, deadline : Time) : Decision?
          while Approvals.now < deadline
            memo = @store.try(&.memo_get(memo_key(request_id)))
            if memo
              @mutex.synchronize { @pending.delete(request_id) }
              return Decision.new(memo.starts_with?("approved"), memo)
            end
            sleep 50.milliseconds
          end
          nil
        end
      end
    end
  end
end
