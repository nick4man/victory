# frozen_string_literal: true

# Sentry error tracking — gated на SENTRY_DSN.
# Если ENV не задан → init не вызывается (sentry-ruby становится no-op).
# Это важно для local dev / тестов — не хотим засорять Sentry events
# из чьих-либо локальных запусков.

return unless ENV['SENTRY_DSN'].present?

require 'sentry-ruby'
require 'sentry-rails'
require 'sentry-sidekiq' if defined?(Sidekiq)

Sentry.init do |config|
  config.dsn = ENV.fetch('SENTRY_DSN')

  # Environment — production / staging / development.
  config.environment = ENV.fetch('SENTRY_ENVIRONMENT', Rails.env)

  # Release tracking — Git SHA из CI / deploy-скрипт. Без неё releases
  # не group'ятся в Sentry UI и regression tracking ломается.
  if (sha = ENV['SENTRY_RELEASE'].presence || ENV['GIT_COMMIT_SHA'].presence)
    config.release = "victory62@#{sha[0..7]}"
  end

  # Включаем breadcrumbs из ActiveSupport notifications (SQL, view rendering,
  # Sidekiq job lifecycle). Helps reconstruct what happened around error.
  config.breadcrumbs_logger = %i[active_support_logger http_logger]

  # Performance monitoring — low sample rate to keep cost down на free tier
  # (Sentry charges по событиям + traces). 5% даёт enough data чтобы найти
  # медленные endpoints без burn'a квоты.
  config.traces_sample_rate = ENV.fetch('SENTRY_TRACES_SAMPLE_RATE', '0.05').to_f
  config.send_default_pii   = false                              # critical: 152-ФЗ
  config.max_breadcrumbs    = 50

  # Игнорируем noise который не actionable:
  #   - ActionController::RoutingError → 404s от bot scanners
  #   - Net::OpenTimeout / SocketError → transient network (retry handles)
  config.excluded_exceptions += %w[
    ActionController::RoutingError
    ActionController::InvalidAuthenticityToken
    ActionDispatch::Http::Parameters::ParseError
  ]

  # before_send — PII strip перед отправкой к Sentry. Дублирует
  # filter_parameter_logging, но Sentry имеет свой context (request,
  # user, tags) который не покрывается ActiveSupport::ParameterFilter.
  config.before_send = lambda do |event, _hint|
    scrub_pii!(event)
    event
  end
end

# Top-level scrubber — fields никогда не должны уехать в Sentry.
# Mirror'ит filter_parameter_logging.rb categories + adds sentry-specific
# context locations.
def scrub_pii!(event)
  sensitive_keys = %w[
    password password_confirmation secret token api_key authentication_token
    passport_number passport_series passport_data inn snils birth_date issued_by
    card_number cvv iban bik
    phone email full_name address message comment identifier
    yandex_webmaster_token oauth_token access_token refresh_token authorization
    parsed_data ocr_raw_text yandex_vision_response
  ].freeze

  scrub_hash = ->(hash) {
    return unless hash.is_a?(Hash)
    hash.each_key do |k|
      if sensitive_keys.any? { |sk| k.to_s.downcase.include?(sk) }
        hash[k] = '[FILTERED]'
      elsif hash[k].is_a?(Hash)
        scrub_hash.call(hash[k])
      end
    end
  }

  # Sentry event has request.data, request.headers, extra, contexts
  scrub_hash.call(event.request.data)         if event.respond_to?(:request) && event.request
  scrub_hash.call(event.request.headers)      if event.respond_to?(:request) && event.request
  scrub_hash.call(event.extra)                if event.respond_to?(:extra)
  scrub_hash.call(event.contexts)             if event.respond_to?(:contexts)

  # User context — Sentry автомат прикручивает current_user.id/email из
  # Devise. У нас Devise off, но на всякий — strip emails.
  if event.respond_to?(:user) && event.user.is_a?(Hash)
    event.user.delete('email')
    event.user.delete(:email)
  end
end
