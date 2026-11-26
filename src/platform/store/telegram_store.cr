# frozen_string_literal: true

# Telegram 落库与恢复扫描（M3-WP8，自 store.cr 拆分——体量闸，SteerStoreMethods 同款模式）：
# telegram_accounts 轮询状态（persisted_offset / last_update_at / reset_mode）+
# telegram_updates 写入顺序纪律三步支撑（先落库 → 再推进 offset → 再入总线）。
# DDL 仍在 store.cr 的 SCHEMA（唯一定义处），本文件只承载读写方法。
#
# 契约：m8 提案 §4.2「Telegram 空闲后 update_id 重置策略」——
# - Step 1 持久化：INSERT 冲突（指纹唯一索引/event_id 主键）不算失败，返回 false 由调用方
#   按「已持久化」继续（崩溃窗口 A：Step 1 后、Step 2 前崩溃，重启后 Telegram 重推同 update）；
# - Step 2 推进 offset：只在持久化成功（含冲突已存在）后调用，绝不提前；
# - Step 3 入总线后的 dispatched=true 由消费者侧经 mark/confirm 置位，生产者不置位；
# - 重置模式退出：persisted_offset 与 reset_mode 同事务（exit_telegram_reset_mode），
#   分开写会留下「offset 已推进但 reset_mode 仍 true」的半完成态。
module Sebas
  module Platform
    # Store include 本 module 获得 Telegram 读写方法（include 行在 store.cr class Store 内）
    module TelegramStoreMethods
      record TelegramAccountState,
        persisted_offset : Int64, last_update_at : String?, reset_mode : Bool

      record TelegramUpdateRow,
        event_id : String, account_id : String, update_id : Int64,
        content_fingerprint : String, raw_payload : String, dispatched : Bool,
        status : String, retry_count : Int64, bus_publish_timeout_count : Int64, created_at : String

      # 账号轮询状态（无行返回默认：未确认过任何 update、活跃窗口、非重置模式）
      def telegram_account_state(account_id : String) : TelegramAccountState
        @db.query_one?(
          "SELECT persisted_offset, last_update_at, reset_mode FROM telegram_accounts WHERE account_id = ?",
          account_id
        ) do |result_set|
          TelegramAccountState.new(
            result_set.read(Int64), result_set.read(String?), result_set.read(Int64) != 0)
        end || TelegramAccountState.new(0_i64, nil, false)
      end

      # 账号行登记（幂等；adapter 启动时调用）
      def ensure_telegram_account(account_id : String) : Nil
        @db.exec("INSERT OR IGNORE INTO telegram_accounts (account_id, persisted_offset, reset_mode) VALUES (?, 0, 0)", account_id)
      end

      # 非空响应到达即刷新空闲基准（提案 §4.2：到达时刻落库，不得推迟到退出重置模式——
      # 否则 Step 1–3 阻塞会推迟计时起点，Telegram 第 7 天投递的小 ID update 会被活跃模式跳过）
      def touch_telegram_last_update(account_id : String, at : String) : Nil
        @db.exec("UPDATE telegram_accounts SET last_update_at = ? WHERE account_id = ?", at, account_id)
      end

      # Step 1：落库（dispatched=false, status='pending'）。返回 false = 已存在
      # （指纹唯一索引或 event_id 主键冲突），不视为失败——调用方读该行 dispatched
      # 标记决定 Step 3 是否重投。
      def persist_telegram_update(event_id : String, account_id : String, update_id : Int64,
                                  content_fingerprint : String, raw_payload : String) : Bool
        rows = @db.exec(
          "INSERT OR IGNORE INTO telegram_updates " \
          "(event_id, account_id, update_id, content_fingerprint, raw_payload, dispatched, status, retry_count, bus_publish_timeout_count, created_at) " \
          "VALUES (?, ?, ?, ?, ?, 0, 'pending', 0, 0, ?)",
          event_id, account_id, update_id, content_fingerprint, raw_payload, now
        ).rows_affected
        rows > 0
      end

      # Step 2：持久化成功后才推进 offset（下次 getUpdates(offset=persisted_offset+1) 确认旧值）
      def advance_telegram_offset(account_id : String, update_id : Int64) : Nil
        @db.exec(
          "UPDATE telegram_accounts SET persisted_offset = ? WHERE account_id = ? AND persisted_offset < ?",
          update_id, account_id, update_id
        )
      end

      # 进入重置模式（空闲 ≥6 天判定成立时；跨崩溃延续）
      def enter_telegram_reset_mode(account_id : String) : Nil
        @db.exec("UPDATE telegram_accounts SET reset_mode = 1 WHERE account_id = ?", account_id)
      end

      # 重置模式退出：offset 重置为本轮最大 update_id 与 reset_mode=false 同一事务（提案 §4.2 退出条件）
      def exit_telegram_reset_mode(account_id : String, new_offset : Int64) : Nil
        @db.transaction do |tx|
          tx.connection.exec("UPDATE telegram_accounts SET persisted_offset = ? WHERE account_id = ?", new_offset, account_id)
          tx.connection.exec("UPDATE telegram_accounts SET reset_mode = 0 WHERE account_id = ?", account_id)
        end
      end

      # Step 3 确认置位：消费者 record_intent 落库成功（含已有 intent 提前返回分支）后调用，
      # 生产者 Bus#publish 返回后不置位（提案 §4.2 Step 3 纪律）
      def mark_telegram_dispatched(event_id : String) : Nil
        @db.exec("UPDATE telegram_updates SET dispatched = 1 WHERE event_id = ?", event_id)
      end

      # 补确认置位（提案 §4.2「已有 admission 的恢复记录补确认」）：intents 表中该
      # event_id 状态为 done/dispatched 才置 true；不存在（record_intent 失败）保留
      # false 交调度器扩展（#252）恢复路径处理，不提前确认。
      def confirm_telegram_dispatch(event_id : String) : Bool
        @db.exec(
          "UPDATE telegram_updates SET dispatched = 1 " \
          "WHERE event_id = ? AND dispatched = 0 " \
          "AND EXISTS (SELECT 1 FROM intents WHERE intents.id = telegram_updates.event_id AND intents.status IN ('done', 'dispatched'))",
          event_id
        ).rows_affected > 0
      end

      # 全量补确认（启动 recover_dispatch 后统一执行）：单条 SQL 扫描全部
      # dispatched=false 行，intent 已 done/dispatched 的补置位（窗口 C：record_intent
      # 成功、确认回调前崩溃的存量行一次性收敛）
      def confirm_telegram_dispatches : Int32
        @db.exec(
          "UPDATE telegram_updates SET dispatched = 1 " \
          "WHERE dispatched = 0 AND status != 'dead_letter' " \
          "AND EXISTS (SELECT 1 FROM intents WHERE intents.id = telegram_updates.event_id AND intents.status IN ('done', 'dispatched'))"
        ).rows_affected.to_i32
      end

      # 恢复扫描候选（启动 + 运行期周期扫描共用）：dispatched=false 且
      # status != 'dead_letter'，按 update_id 升序重建投递
      def pending_telegram_updates(account_id : String) : Array(TelegramUpdateRow)
        rows = [] of TelegramUpdateRow
        @db.query(
          "SELECT event_id, account_id, update_id, content_fingerprint, raw_payload, dispatched, status, retry_count, bus_publish_timeout_count, created_at " \
          "FROM telegram_updates WHERE account_id = ? AND dispatched = 0 AND status != 'dead_letter' ORDER BY update_id",
          account_id
        ) do |result_set|
          result_set.each { rows << read_telegram_update(result_set) }
        end
        rows
      end

      def telegram_update(event_id : String) : TelegramUpdateRow?
        @db.query_one?(
          "SELECT event_id, account_id, update_id, content_fingerprint, raw_payload, dispatched, status, retry_count, bus_publish_timeout_count, created_at " \
          "FROM telegram_updates WHERE event_id = ?", event_id
        ) { |result_set| read_telegram_update(result_set) }
      end

      def telegram_dispatched?(event_id : String) : Bool
        @db.query_one?("SELECT dispatched FROM telegram_updates WHERE event_id = ?", event_id) do |result_set|
          result_set.read(Int64) != 0
        end || false
      end

      # record_intent 失败计数（max_dispatch_retries 上限控制；调度器扩展 #252 消费）
      def bump_telegram_retry(event_id : String) : Nil
        @db.exec("UPDATE telegram_updates SET retry_count = retry_count + 1 WHERE event_id = ?", event_id)
      end

      # bus 饱和观测计数（不影响生命周期；Bus#publish 阻塞超时的观测面）
      def bump_telegram_bus_timeout(event_id : String) : Nil
        @db.exec("UPDATE telegram_updates SET bus_publish_timeout_count = bus_publish_timeout_count + 1 WHERE event_id = ?", event_id)
      end

      # 死信：两条扫描路径（启动 + 周期）都不再选中（status 条件排除）
      def mark_telegram_dead_letter(event_id : String) : Nil
        @db.exec("UPDATE telegram_updates SET status = 'dead_letter' WHERE event_id = ?", event_id)
      end

      private def read_telegram_update(result_set : ::DB::ResultSet) : TelegramUpdateRow
        TelegramUpdateRow.new(
          result_set.read(String), result_set.read(String), result_set.read(Int64),
          result_set.read(String), result_set.read(String), result_set.read(Int64) != 0,
          result_set.read(String), result_set.read(Int64), result_set.read(Int64), result_set.read(String))
      end
    end
  end
end
