require "../../platform/store/store"
require "../../platform/bus/bus"
require "json"

# Telegram long-poll 轮询状态机（M3-WP8；m8 提案 §4.2 全文为契约）。
#
# 双模：活跃窗口（offset 轮询 + 单调排重）⇄ 空闲重置模式（无 offset 拉全集 +
# 内容指纹排重）。空闲判定：last_update_at 距今 ≥6 天（官方阈值一周留 1 天边际）
# 或持久化 reset_mode=true（跨崩溃延续——只看 last_update_at 不够：重置模式下
# 收到小 ID update 先刷 last_update_at，若在落库前崩溃会被误判回活跃窗口）。
#
# 写入顺序纪律（每条 update）：
#   Step 1 落库 telegram_updates（dispatched=false；唯一冲突=已持久化，不算失败）
#   → Step 2 推进 persisted_offset（仅活跃模式；绝不在持久化前推进）
#   → Step 3 入总线（Bus#publish；dispatched=true 由消费者侧置位，生产者不置）。
#
# 恢复：启动扫描 + 运行期周期扫描重投 dispatched=false 且 status != 'dead_letter'
# 的行（event_id 按行主键重建，与原投递同值）。窗口 C（record_intent 成功、
# 消费者确认前崩溃）由 gateway 侧补确认路径收敛（scheduler duplicate 分支 +
# recover_dispatch 后全量扫描），本层不负责。
module Sebas
  module Channels
    module Telegram
      class LongPoll
        # 官方「至少一周无 update 后 update_id 可能重置」；留 1 天安全边际
        RESET_AFTER = 6.days
        Log         = Sebas::Log.for("channels.telegram.longpoll")

        enum Outcome
          Empty          # 空响应（不刷新空闲基准；重置模式下不退出）
          ActiveAdvanced # 活跃模式处理了 ≥1 条 update
          ResetExited    # 重置模式收到新 update 并已同事务退出
        end

        getter account_id : String

        # clock 注入（spec 控制空闲判定；生产用 Time.utc）
        def initialize(@account_id : String, @api : BotApi, @store : ::Sebas::Platform::Store::Store,
                       @bus : ::Sebas::Platform::Bus::Bus,
                       @clock : -> ::Time = -> { ::Time.utc })
          # 账号行是轮询状态的持久底座（touch/advance 都 UPDATE 此行）——LongPoll
          # 自身防御性登记，不依赖 adapter 装配顺序（幂等 INSERT OR IGNORE）
          @store.ensure_telegram_account(@account_id)
        end

        # 完整运行循环（adapter fiber 调用；stop 由调用方翻转后由轮询周期感知）
        def run(stop : Atomic(Bool), scan_interval : ::Time::Span = 60.seconds,
                backoff : ::Time::Span = 5.seconds, max_backoff : ::Time::Span = 60.seconds) : Nil
          current_backoff = backoff
          last_scan = ::Time.instant
          recover_pending
          until stop.get
            begin
              poll_once
              current_backoff = backoff
            rescue ex : BotApiError
              Log.warn { "getUpdates failed (account=#{@account_id}): #{ex.message}; backoff #{current_backoff}" }
              sleep current_backoff
              current_backoff = Math.min(current_backoff * 2, max_backoff)
            end
            # 运行期恢复：周期扫描重投 dispatched=false 行（与启动扫描同构）
            if ::Time.instant - last_scan >= scan_interval
              recover_pending
              last_scan = ::Time.instant
            end
          end
        end

        # 重置模式判定（提案 §4.2：reset_mode=true OR last_update_at 距今 ≥6 天）。
        # last_update_at=nil=从未交付过：按活跃窗口处理——此时 persisted_offset=0，
        # 活跃模式同样不传 offset 拉全集，且逐条推进即可建立 offset，无需重置语义。
        def reset_mode? : Bool
          state = @store.telegram_account_state(@account_id)
          return true if state.reset_mode
          last = state.last_update_at
          return false if last.nil?
          @clock.call - ::Time.parse_rfc3339(last) >= RESET_AFTER
        end

        # 恢复扫描（启动 + 周期共用）：按 update_id 升序重投未确认行。
        # event_id 用行主键重建（确定性派生的同一值，提案 §4.2 启动恢复条）。
        # 已 dispatched=true 的行两条路径都不再投递（含 dead_letter，SQL 已排除）。
        def recover_pending : Int32
          count = 0
          @store.pending_telegram_updates(@account_id).each do |row|
            chat_id, message_id, text = Telegram.parse_message_payload(row.raw_payload)
            @bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
              row.event_id, "telegram", row.account_id, chat_id || "", text || "", message_id))
            count += 1
          end
          Log.info { "telegram recover scan re-published #{count} pending updates (account=#{@account_id})" } if count.positive?
          count
        end

        # 一次轮询迭代（活跃或重置模式自适配；spec 直接循环调用，无需真 fiber）
        def poll_once : Outcome
          if reset_mode?
            poll_reset_once
          else
            poll_active_once
          end
        end

        # 活跃窗口：offset=persisted_offset+1 确认旧值（persisted_offset=0 时
        # 不传 offset——Telegram 从未对本账号确认过任何值）
        private def poll_active_once : Outcome
          state = @store.telegram_account_state(@account_id)
          offset = state.persisted_offset.positive? ? state.persisted_offset + 1 : nil
          updates = @api.get_updates(offset)
          return Outcome::Empty if updates.empty?
          # 非空响应到达即落库空闲基准（空响应不刷新——连续空闲须能达 6 天阈值）
          @store.touch_telegram_last_update(@account_id, @clock.call.to_rfc3339)
          floor = state.persisted_offset # 循环起点快照：批内逐条推进后不误跳后续 update
          updates.each do |update|
            # 单调排重：≤ 已确认 offset 直接跳过；同 ID 重推由指纹唯一索引兜底
            next if update.update_id <= floor
            process_update(update, advance_offset: true)
          end
          Outcome::ActiveAdvanced
        end

        # 重置模式：不传 offset 拉未确认全集；空轮询不退出（恢复旧 offset 会让
        # 重置后的较小新 ID 被确认跳过，与本策略目的直接冲突）；本轮全部持久化
        # + 入总线成功后同事务退出（offset=本轮最大 update_id、reset_mode=false）。
        private def poll_reset_once : Outcome
          updates = @api.get_updates(nil)
          return Outcome::Empty if updates.empty?
          @store.touch_telegram_last_update(@account_id, @clock.call.to_rfc3339)
          @store.enter_telegram_reset_mode(@account_id)
          max_id = 0_i64
          updates.each do |update|
            process_update(update, advance_offset: false)
            max_id = update.update_id if update.update_id > max_id
          end
          @store.exit_telegram_reset_mode(@account_id, max_id)
          Log.info { "telegram reset mode exited (account=#{@account_id}, offset=#{max_id})" }
          Outcome::ResetExited
        end

        # Step 1–3 单条处理（活跃/重置共用）。
        # advance_offset：活跃模式 Step 2 照常推进；重置模式暂不推进（退出时同事务写）。
        private def process_update(update : Update, advance_offset : Bool) : Nil
          event_id = update.event_id(@account_id)
          # Step 1 持久化。INSERT 冲突（event_id 主键/指纹唯一索引）= 之前已落库
          # （典型：Step 1 后、Step 2 前崩溃，重启后 Telegram 重推同一条）——不视为
          # 失败，Step 2 照常推进（提案 §4.2：唯一索引冲突被视为已持久化）。
          inserted = @store.persist_telegram_update(
            event_id, @account_id, update.update_id, update.content_fingerprint, update.raw_payload)

          if inserted && update.chat_id.nil?
            # 非消息类 update（无 chat 可投，如 callback_query）：落库推进 offset
            # 但不入总线；无总线投递即无消费者确认环节，直接置 dispatched，
            # 否则该行会被恢复扫描永久重投。
            @store.mark_telegram_dispatched(event_id)
            advance_offset_or_noop(update, advance_offset)
            return
          end

          # Step 2 推进 offset（持久化成功或冲突已存在，均视为已持久化；绝不提前）
          advance_offset_or_noop(update, advance_offset)

          # Step 3 入总线。冲突行已 dispatched=true 的跳过（已投过，不重复投递）；
          # dispatched=false 的照常执行（窗口 A：落库后未及入总线的残留）。
          # Bus#publish 成功返回 ≠ 处理完成（消费者 record_intent 才是），dispatched
          # 保持 false 直到消费者侧置位（gateway.process_message / scheduler 补确认）。
          return if !inserted && @store.telegram_dispatched?(event_id)
          @bus.publish(::Sebas::Platform::Bus::InboundMessage.new(
            event_id, "telegram", @account_id, update.chat_id || "", update.text || "", update.message_id))
        end

        private def advance_offset_or_noop(update : Update, advance_offset : Bool) : Nil
          @store.advance_telegram_offset(@account_id, update.update_id) if advance_offset
        end
      end

      # raw_payload → (chat_id, message_id, text)（恢复扫描重建消息用；
      # 与 BotApi#parse_update 同一字段口径）
      def self.parse_message_payload(raw_payload : String) : Tuple(String?, String?, String?)
        data = ::JSON.parse(raw_payload)
        message = data["message"]?
        return {nil, nil, nil} unless message
        chat_id = message.dig?("chat", "id").try(&.to_s)
        message_id = message["message_id"]?.try(&.to_s)
        text = message["text"]?.try(&.as_s?) || message["caption"]?.try(&.as_s?)
        {chat_id, message_id, text}
      end
    end
  end
end
