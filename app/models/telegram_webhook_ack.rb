# frozen_string_literal: true

# Phase 9 Iter 8 — Idempotency record per Telegram update_id.
# Создаётся в InboundProcessor#call ПЕРЕД обработкой; дубликаты raise
# RecordNotUnique → return :duplicate без side-effects.
class TelegramWebhookAck < ApplicationRecord
  validates :update_id,    presence: true, uniqueness: { scope: :bot }
  validates :bot,          inclusion: { in: Telegram::BotContext::BOTS }
  validates :processed_at, presence: true

  scope :stale, ->(older_than: 7.days.ago) { where(processed_at: ...older_than) }
end
