# frozen_string_literal: true

# Phase 15 — search engine для группового чата.
# Сейчас InboxSaver сохраняет messages в /app/inbox/<date>/*.json (backup).
# Этой таблицы достаточно для FTS поиска без re-parse JSON-файлов.
#
# Schema: только supergroup/group messages (DM не индексируем — privacy).
# body — text || caption combined; tsvector generated column для русской FTS
# через `to_tsvector('russian', ...)`. GIN-индекс для быстрого @@-match'а.
#
# pg_trgm + russian dict уже включены через миграцию 20260509211400.
#
# Volume estimate: ~500 msg/день × 365 = 180K rows/год.
# tsv index ~30-50 MB — manageable.
class CreateTelegramGroupMessages < ActiveRecord::Migration[7.1]
  def up
    create_table :telegram_group_messages do |t|
      t.bigint   :tg_chat_id,            null: false
      t.bigint   :tg_message_id,         null: false
      t.bigint   :tg_thread_id           # forum topic (#КВАРТИРЫ etc); nil для general
      t.bigint   :tg_user_id             # sender's TG id
      t.string   :sender_username, limit: 64
      t.string   :sender_first_name, limit: 120
      t.text     :body                   # text || caption (что есть)
      t.string   :payload_kind, limit: 16, default: 'text', null: false
      t.boolean  :has_attachment, default: false, null: false
      t.bigint   :reply_to_tg_message_id # для thread'ов разговора в общем чате
      t.datetime :sent_at, null: false
      t.timestamps
    end

    add_index :telegram_group_messages, %i[tg_chat_id tg_message_id], unique: true,
                                                                       name: 'idx_tg_group_msg_chat_msg_uniq'
    add_index :telegram_group_messages, %i[tg_user_id sent_at]
    add_index :telegram_group_messages, %i[tg_thread_id sent_at]
    add_index :telegram_group_messages, :sent_at

    # Raw SQL: generated tsvector column + GIN индекс.
    # Используем 'russian' dictionary — морфология лемматизации.
    # Generated column = автоматический пересчёт при INSERT/UPDATE body —
    # никакой sync-логики в Ruby.
    execute <<~SQL
      ALTER TABLE telegram_group_messages
        ADD COLUMN body_tsv tsvector
        GENERATED ALWAYS AS (to_tsvector('russian', COALESCE(body, ''))) STORED;
    SQL

    execute <<~SQL
      CREATE INDEX idx_tg_group_msg_body_tsv
        ON telegram_group_messages USING gin(body_tsv);
    SQL
  end

  def down
    execute 'DROP INDEX IF EXISTS idx_tg_group_msg_body_tsv;'
    drop_table :telegram_group_messages
  end
end
