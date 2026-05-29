# frozen_string_literal: true

# Lightweight reader for the audit-engine's current macro snapshot
# (`/api/v2/macro/latest`). The engine's APScheduler refreshes the CB RF
# key rate daily at 06:00 МСК; we cache the result in Rails.cache for an
# hour so audit-form requests don't fan out to the engine.
#
# Output shape:
#   {
#     key_rate: 14.5,        # СВЕЖАЯ ключевая ставка ЦБ
#     mortgage_rate: 16.5,   # производная: key + 2 (engine derivation)
#     deposit_rate: 13.5,    # производная: key - 1
#     inflation: 5.9 | nil,  # CB inflation, если spider набрал
#     effective_date: "2026-05-11",
#     source: "cbr.ru SOAP KeyRate",
#     stale: false           # true → engine не вернул валидные данные
#   }
class MacroRatesService
  CACHE_KEY = 'audit_engine:macro_latest:v2'
  CACHE_TTL = 1.hour

  def self.call
    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { fetch }
  end

  def self.bust!
    Rails.cache.delete(CACHE_KEY)
  end

  def self.fetch
    data = AuditEngine::Client.new.macro_latest
    key_rate = data['cbr_key_rate']&.to_f
    return fallback unless key_rate&.positive?

    {
      key_rate: key_rate,
      mortgage_rate: (key_rate + 2.0).round(1),
      deposit_rate: (key_rate - 1.0).round(1),
      inflation: data['inflation_annual']&.to_f,
      effective_date: data['date'],
      source: data['source'] || 'cbr.ru',
      stale: false
    }
  rescue AuditEngine::Error, StandardError => e
    Rails.logger.warn("[MacroRatesService] engine unavailable: #{e.class} #{e.message}")
    fallback
  end

  def self.fallback
    {
      key_rate: nil,
      mortgage_rate: nil,
      deposit_rate: nil,
      inflation: nil,
      effective_date: nil,
      source: 'fallback',
      stale: true
    }
  end
end
