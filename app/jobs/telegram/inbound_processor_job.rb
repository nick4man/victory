# frozen_string_literal: true

module Telegram
  # Phase 10 Iter 12 — Async webhook dispatch. Долгие flows (voice 10-25s,
  # photo intake 5-10s) держали TG webhook connection → retries → cost burn.
  # Now: controller вернёт 200 за ~50ms, processing — в Sidekiq.
  class InboundProcessorJob
    include Sidekiq::Job
    # default queue — high-priority; ack в TG нужен FAST.
    sidekiq_options queue: :default, retry: 1

    # bot — чей вебхук принял апдейт ('main' | 'test'). Параметр со значением
    # по умолчанию: джобы, уже лежащие в очереди с одним аргументом, работают.
    def perform(payload_json, bot = 'main')
      payload = payload_json.is_a?(Hash) ? payload_json : JSON.parse(payload_json.to_s)
      Telegram::BotContext.within(bot) { Telegram::InboundProcessor.new(payload).call }
    rescue StandardError => e
      Rails.logger.error("[Telegram::InboundProcessorJob] #{e.class}: #{e.message}")
      raise # let Sidekiq retry catch
    end
  end
end
