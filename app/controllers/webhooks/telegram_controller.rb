# frozen_string_literal: true

module Webhooks
  # Telegram bot webhook: dispatched to InboundProcessor which matches
  # reply-to messages back to a Conversation and posts agent reply into
  # the chat widget via ActionCable.
  #
  # Auth: TG forwards a `X-Telegram-Bot-Api-Secret-Token` header if you
  # set secret_token при setWebhook(). Поскольку наш TG → CF Worker →
  # Rails, проверяем заголовок ТОЛЬКО когда ENV['TELEGRAM_WEBHOOK_SECRET']
  # настроен (graceful — backward compat если ops ещё не задал секрет).
  # Setup: `setWebhook(secret_token: ENV.fetch('TELEGRAM_WEBHOOK_SECRET'))`.
  class TelegramController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false

    def create
      return unauthorized unless valid_signature?

      payload = parse_payload
      # Phase 10 Iter 12 — async dispatch. Возвращаем 200 за ~50ms; processing
      # в Sidekiq. Voice/photo flows (10-25s) больше не блокируют TG webhook.
      # Iter 8 dedup на update_id catches concurrent retries.
      Telegram::InboundProcessorJob.perform_async(payload) if payload.present?

      head :ok
    rescue StandardError => e
      Rails.logger.error("[Telegram webhook] #{e.class} #{e.message}")
      head :ok # always 200 — Telegram retries non-2xx aggressively
    end

    private

    def valid_signature?
      expected = ENV['TELEGRAM_WEBHOOK_SECRET'].to_s
      # Если секрет не настроен — пропускаем (миграционный grace), но
      # пишем в лог чтобы ops знали что нужен setWebhook + ENV.
      if expected.blank?
        Rails.logger.warn('[Telegram webhook] TELEGRAM_WEBHOOK_SECRET not set — webhook unsigned')
        return true
      end

      provided = request.headers['X-Telegram-Bot-Api-Secret-Token'].to_s
      return false if provided.blank?

      ActiveSupport::SecurityUtils.secure_compare(provided, expected)
    end

    def unauthorized
      Rails.logger.warn(
        "[Telegram webhook] rejected: secret_token mismatch from ip=#{request.remote_ip}"
      )
      head :unauthorized
    end

    def parse_payload
      raw = request.body.read
      return {} if raw.blank?
      JSON.parse(raw)
    rescue JSON::ParserError
      params.to_unsafe_h.except(:controller, :action).stringify_keys
    end
  end
end
