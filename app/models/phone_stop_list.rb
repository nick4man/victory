# frozen_string_literal: true

# 152-ФЗ — registry для phones исключённых из любых outbound channels.
# См. migration `db/migrate/.../create_phone_stop_lists.rb` для полного
# обоснования и use-cases.
#
# Canonical form — last 10 digits ('9009694844'). Normalize'ится через
# `.normalize(phone)` независимо от формата input'а.
class PhoneStopList < ApplicationRecord
  default_scope { where(deleted_at: nil) }

  belongs_to :added_by_user, class_name: 'User', optional: true

  SOURCES = %w[admin self system import].freeze

  validates :phone_last10, presence: true, length: { is: 10 },
                            format: { with: /\A\d{10}\z/ }
  validates :phone_last10, uniqueness: { conditions: -> { where(deleted_at: nil) } }
  validates :reason, presence: true, length: { maximum: 500 }
  validates :added_by, presence: true, inclusion: { in: SOURCES }

  scope :active, -> { where('expires_at IS NULL OR expires_at > ?', Time.current) }

  # @return [Boolean] true если phone в active stop-list (бессрочно ИЛИ не истёк)
  # @param phone [String] in any format: '+79009694844', '79009694844', etc.
  def self.blocked?(phone)
    normalized = normalize(phone)
    return false if normalized.nil?
    active.where(phone_last10: normalized).exists?
  end

  # @return [String, nil] last-10-digits если можно canonicalize, иначе nil
  def self.normalize(phone)
    digits = phone.to_s.gsub(/\D/, '')
    return nil if digits.length < 10
    digits.last(10)
  end

  # Helper для adding с auto-normalize phone input.
  def self.add!(phone:, reason:, added_by: 'admin', added_by_user: nil, source_note: nil, expires_at: nil)
    normalized = normalize(phone) or raise ArgumentError, "invalid phone: #{phone.inspect}"
    create!(
      phone_last10:  normalized,
      reason:        reason,
      added_by:      added_by,
      added_by_user: added_by_user,
      source_note:   source_note,
      expires_at:    expires_at
    )
  end

  def destroy
    update!(deleted_at: Time.current)
  end

  def display_phone
    "+7#{phone_last10}"
  end
end
