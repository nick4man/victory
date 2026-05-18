# frozen_string_literal: true

# Phase 9 Iter 5 — Idempotency для повторных photo uploads.
# Клиент шлёт one photo дважды (повтор от плохого инета) — раньше создавалось
# 2 ClientDocument + 2 ParserJob → 2 Groq API charge + 2 NC mirror.
# Теперь — unique index гарантирует один документ per (tg_chat_id, tg_message_id).
#
# Partial index WHERE deleted_at IS NULL — позволяет восстановить документ
# после soft-delete без блокировки нового.
class AddUniqueIntakeToClientDocuments < ActiveRecord::Migration[7.1]
  def change
    add_index :client_documents,
              [:tg_chat_id, :tg_message_id],
              unique: true,
              where: 'tg_chat_id IS NOT NULL AND tg_message_id IS NOT NULL',
              name: 'idx_client_documents_tg_intake_unique'
  end
end
