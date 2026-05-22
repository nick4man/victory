# frozen_string_literal: true

# Single-use state-token для Telegram opt-in linking. Mirrors MagicLinkToken
# pattern (30-min TTL, single-use, SecureRandom.urlsafe_base64).
#
# Flow:
#   1. User clicks «Подключить TG» в /cabinet/profile
#      → controller вызывает TgLinkToken.generate!(user: current_user, request:)
#      → возвращает token, контроллер делает redirect на
#        https://t.me/<TG_BOT_NAME>?start=<token>
#   2. Telegram bot получает /start <token> в private chat
#      → Telegram::ClientBot::LinkProcessor.call(token:, tg_user_id:, username:)
#      → token.consume!(tg_user_id:, username:) → User.update!
#   3. Bot reply'ит клиенту confirmation
#
# Security:
#   - 30-min TTL (короче opt-in flow редко занимает > минуты)
#   - single-use (consumed_at NOT NULL после consume!)
#   - Token leak в email forwarding / screenshot — minimal risk
#     потому что чтобы exploit'нуть нужен ещё access к TG аккаунту клиента
#   - НО мы не позволяем re-link если user.tg_user_id уже set (см. consume!)
class TgLinkToken < ApplicationRecord
  TTL = 30.minutes

  belongs_to :user

  validates :token, :expires_at, presence: true
  validates :token, uniqueness: true

  scope :valid, -> { where(consumed_at: nil).where('expires_at > ?', Time.current) }

  def self.generate!(user:, request: nil)
    create!(
      user:       user,
      token:      SecureRandom.urlsafe_base64(32),
      expires_at: TTL.from_now,
      ip_address: request&.remote_ip,
      user_agent: request&.user_agent.to_s.first(255).presence
    )
  end

  # Atomic claim — race-safe против double-/start.
  # Returns [user, nil] on success, [nil, error_code] on failure.
  # Error codes: :not_found, :expired, :already_consumed, :user_already_linked,
  #              :tg_user_already_linked_to_other
  def self.consume!(raw_token:, tg_user_id:, tg_username: nil)
    return [nil, :not_found] if raw_token.blank?

    transaction do
      record = lock.find_by(token: raw_token)
      return [nil, :not_found]        if record.nil?
      return [nil, :already_consumed] if record.consumed_at.present?
      return [nil, :expired]          if record.expires_at <= Time.current

      user = record.user
      # Защита: уже подключён к ДРУГОМУ tg-аккаунту → требуется ручной reset
      # (cabinet UI «Отключить» сначала).
      if user.tg_user_id.present? && user.tg_user_id != tg_user_id
        return [nil, :user_already_linked]
      end

      # Защита: этот tg_user_id уже linked к ДРУГОМУ User (unique index это
      # тоже поймает на DB-level, но даём user-friendly код).
      other = User.where(tg_user_id: tg_user_id).where.not(id: user.id).first
      return [nil, :tg_user_already_linked_to_other] if other

      user.update!(
        tg_user_id:   tg_user_id,
        tg_username:  tg_username.to_s.delete('@').presence,
        tg_linked_at: Time.current
      )
      record.update!(consumed_at: Time.current)
      [user, nil]
    end
  end

  def consumed?
    consumed_at.present?
  end

  def expired?
    expires_at <= Time.current
  end
end
