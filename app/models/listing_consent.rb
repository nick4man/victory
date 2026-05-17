# frozen_string_literal: true

# Digital agency contract signing record. Когда client clicks «Согласен на
# публикацию и принимаю агентский договор» в /cabinet/listings/:id/consent —
# создаётся ListingConsent с:
#   - signed_at, IP, UA (legal proof)
#   - consent_text (full agreement copy на момент signing)
#   - consent_version (string, e.g. 'v1-2026-05-17')
#   - content_hash (SHA-256 of consent_text — tamper-detection)
#   - token (для public verify URL `/verify-contract/:token` через QR)
#
# Lifecycle:
#   1. Property.status_pending_consent! (admin создал листинг)
#   2. Email → magic-link → /cabinet/listings/:id/consent
#   3. POST consent → ListingConsent.create! → Property.status_active!
#   4. Optional: revoke (client отозвал) → revoked_at, Property → pending_consent again
#
# Active scope: signed AND not revoked.
class ListingConsent < ApplicationRecord
  CURRENT_VERSION = 'v1-2026-05-17'

  belongs_to :property
  belongs_to :user

  validates :token, :signed_at, :consent_text, :consent_version, :content_hash,
            presence: true
  validates :token, uniqueness: true

  # Только один active consent per (property, user) — если revoked, можно
  # subscribe заново. Active = revoked_at IS NULL.
  validates :user_id, uniqueness: {
    scope:      :property_id,
    conditions: -> { where(revoked_at: nil) },
    message:    'уже подписал согласие на этот объект'
  }

  scope :active,  -> { where(revoked_at: nil) }
  scope :revoked, -> { where.not(revoked_at: nil) }
  scope :recent,  -> { order(signed_at: :desc) }

  before_validation :generate_token, on: :create
  before_validation :compute_content_hash, on: :create

  # Helper для views — "подписано 17.05.26 12:30, IP 1.2.3.4"
  def signature_summary
    return 'Не подписано' if signed_at.blank?
    return "Отозвано #{revoked_at.strftime('%d.%m.%y %H:%M')}" if revoked?

    "Подписано #{signed_at.strftime('%d.%m.%y %H:%M')} с IP #{ip_address}"
  end

  def revoked?
    revoked_at.present?
  end

  def active?
    !revoked?
  end

  # Tamper-detect: пересчитываем hash от current text, сравниваем с stored.
  # Если text был edited в БД ad-hoc — несоответствие → return false → admin
  # видит red flag в /admin/listing_consents.
  def tamper_check
    Digest::SHA256.hexdigest(consent_text.to_s) == content_hash
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(24)
  end

  def compute_content_hash
    return if consent_text.blank?

    self.content_hash = Digest::SHA256.hexdigest(consent_text)
  end
end
