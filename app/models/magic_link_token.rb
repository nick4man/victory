# frozen_string_literal: true

# Single-use magic-link token для /cabinet auth (non-Devise).
# Lifecycle:
#   1. POST /cabinet/login → MagicLinkToken.generate!(identifier:, ...)
#   2. Mailer (Phase 1) или SMS (Phase 2) шлёт URL с token
#   3. GET /cabinet/verify/:token → token.consume! + session[:cabinet_user_id] set
#
# Security:
#   - 30-минутный TTL, single-use (consumed_at NOT NULL после consume)
#   - SecureRandom.urlsafe_base64(32) — 43-char высокоэнтропийный
#   - identifier нормализуется (email → lowercase, phone → last 10 digits)
#     чтобы независимо от формата input'а matching работал
#   - audit: ip + UA при generate
class MagicLinkToken < ApplicationRecord
  TTL = 30.minutes

  enum identifier_type: { email: 'email', phone: 'phone' }, _prefix: true

  validates :token, :identifier, :expires_at, :identifier_type, presence: true
  validates :token, uniqueness: true

  scope :valid, lambda {
    where(consumed_at: nil).where('expires_at > ?', Time.current)
  }

  def self.generate!(identifier:, identifier_type: 'email', request: nil)
    create!(
      token:           SecureRandom.urlsafe_base64(32),
      identifier:      normalize(identifier, identifier_type),
      identifier_type: identifier_type,
      expires_at:      TTL.from_now,
      ip_address:      request&.remote_ip,
      user_agent:      request&.user_agent.to_s.first(255).presence
    )
  end

  # Canonical form для match'а:
  #   email — strip + downcase
  #   phone — only digits, last 10 (РФ: 79091234567 / 89091234567 / +79091234567 → '9091234567')
  def self.normalize(value, type)
    case type.to_s
    when 'email' then value.to_s.strip.downcase
    when 'phone' then value.to_s.gsub(/\D/, '').last(10)
    else value.to_s.strip
    end
  end

  # Idempotent: возвращает true только при первом успехе.
  def consume!
    return false if consumed_at.present? || expires_at < Time.current

    update!(consumed_at: Time.current)
    true
  end

  def expired?
    expires_at < Time.current
  end
end
