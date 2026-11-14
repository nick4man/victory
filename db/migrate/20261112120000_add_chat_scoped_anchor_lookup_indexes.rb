# frozen_string_literal: true

# Issue #214 — второй чат (тестовый для probe-прогонов чат-бота).
# Telegram гарантирует уникальность message_id только внутри чата, поэтому
# все lookup'ы переведены на пару (chat_id, message_id):
#   * lead_events — composite index под lookup якорей по (tg_chat_id, anchor_message_id)
#   * conversations — unique (telegram_chat_id, telegram_message_id) вместо
#     глобального unique по telegram_message_id (иначе одинаковый ID эскалации
#     в двух чатах давал RecordNotUnique)
class AddChatScopedAnchorLookupIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :lead_events, %i[tg_chat_id anchor_message_id], name: 'idx_lead_events_chat_anchor'

    remove_index :conversations, name: 'index_conversations_on_telegram_message_id'
    add_index :conversations, %i[telegram_chat_id telegram_message_id],
              unique: true, where: 'telegram_message_id IS NOT NULL',
              name: 'index_conversations_on_telegram_chat_and_message'
  end
end
