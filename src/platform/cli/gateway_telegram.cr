# Telegram 接线（M3-WP8，自 gateway.cr 拆分——400 行回归闸）：
# 消费者确认置位 + 账号热换装配。本 module 由 Gateway include，
# 方法直接访问宿主的 @config/@channels/@supervisor/@store 实例变量
# （GatewayDispatch 同款拆分模式：只改代码组织，不改行为）。
#
# 契约：m8 提案 §4.2 Step 3——telegram_updates.dispatched 由消费者侧置位
# （Bus#publish 返回后生产者不置位）；record_intent 失败（无 intent 行）的
# 运行期恢复依赖调度器 failed 批次重试扩展（#252），本层不提前确认。
require "../../channels/telegram/adapter"

module Sebas
  module Platform
    module CLI
      module GatewayTelegram
        # 消费者确认：process_message 在 intent 落库后调用（含「已有 intent 提前
        # 返回」分支——否则该行每次启动被恢复扫描重投、又在此提前返回，永卡
        # dispatched=false）。replay 路径不置位，由 after_recovery 统一收敛。
        private def confirm_telegram_consumer(message : Bus::InboundMessage) : Nil
          @store.mark_telegram_dispatched(message.event_id) if message.channel_type == "telegram"
        end

        # replay_unfinished/recover_dispatch 完成后调用（Gateway#run）：对全部
        # dispatched=false 且非 dead_letter 行统一查 intents 状态（done/dispatched）
        # 补置位——record_intent 成功、消费者确认回调前崩溃（窗口 C）的存量行
        # 在此一次性收敛。
        def confirm_telegram_after_recovery : Nil
          confirmed = @store.confirm_telegram_dispatches
          Log.info { "telegram dispatch confirm scan settled #{confirmed} rows" } if confirmed.positive?
        end

        # 账号热换（apply_config 调用）：增删=监督体启停；新增经
        # register_telegram_adapter（GatewayDispatch，含 ensure_telegram_account）。
        private def reapply_telegram_accounts(new_config : Config::Config) : Nil
          old_ids = @config.channels.telegram.try(&.accounts.map(&.id)) || [] of String
          new_ids = new_config.channels.telegram.try(&.accounts.map(&.id)) || [] of String
          (old_ids - new_ids).each do |removed|
            @channels.remove("telegram", removed)
            @supervisor.remove_account(removed)
          end
          (new_ids - old_ids).each do |added|
            account = new_config.channels.telegram.try(&.accounts.find(&.id.==(added)))
            next unless account
            register_telegram_adapter(account)
          end
        end
      end
    end
  end
end
