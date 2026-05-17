# frozen_string_literal: true

# Phase 7.2 — Контейнер пакета задач от одного voice-сообщения (Оксана →
# DM → транскрипция → LLM extract → preview → confirm/cancel).
#
# Lifecycle:
#   pending_confirm → confirmed (создаёт Task records)
#                  → cancelled (Оксана отменила)
#                  → expired   (>1h без confirm — TaskBatchExpiryJob)
#
# parsed_payload (jsonb) — массив объектов от TaskExtractor:
#   [{ assignee_username:, title:, due_at:, priority:, kind:,
#      related_property_address:, related_property_id: }, ...]
#
# transcript_redacted — PII-маскированный текст; raw transcript НЕ хранится
# (Phase 7.7 DLP). Original voice .ogg уйдёт в Nextcloud audit-trail (7.8b).
class CreateTaskBatches < ActiveRecord::Migration[7.1]
  def change
    create_table :task_batches do |t|
      t.bigint   :created_by_id,        null: false # FK → telegram_users (Оксана)
      t.string   :source,               null: false, default: 'voice' # voice|text|manual
      t.text     :transcript_redacted # PII-masked text (см. Privacy::TranscriptRedactor)
      t.jsonb    :parsed_payload,       null: false, default: {} # tasks array + meta
      t.string   :status,               null: false, default: 'pending_confirm'
      t.bigint   :preview_message_id    # TG message_id с inline-кнопками (для последующего edit)
      t.bigint   :preview_chat_id       # DM chat_id Оксаны (где висит preview)
      t.datetime :confirmed_at
      t.datetime :cancelled_at
      t.datetime :expired_at
      t.datetime :deleted_at, index: true
      t.timestamps
    end

    add_index :task_batches, :created_by_id
    add_index :task_batches, :status
    add_index :task_batches, :created_at
  end
end
