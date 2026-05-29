# frozen_string_literal: true

# Phase 9 Iter 8 — Webhook idempotency на update_id.
#
# Telegram retries webhook на HTTP 5xx / network timeout. Без dedup один
# update обрабатывался бы дважды — duplicate LLM calls, duplicate DM-
# нотификации, duplicate Task creation.
#
# Unique constraint на update_id — повторный INSERT raise'ит RecordNotUnique.
# Cron weekly cleanup для rows старше 7 дней.
class CreateTelegramWebhookAcks < ActiveRecord::Migration[7.1]
  def change
    create_table :telegram_webhook_acks do |t|
      t.bigint :update_id, null: false
      t.datetime :processed_at, null: false
    end
    add_index :telegram_webhook_acks, :update_id, unique: true
    add_index :telegram_webhook_acks, :processed_at
  end
end
