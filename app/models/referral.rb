# frozen_string_literal: true

# Phase 3 MLS/YRL — лид-передача партнёрскому агентству. Один Referral =
# один Inquiry на чужой объект, передаваемый за commission share.
#
# State machine (string status enum, не AR enum — нужна гибкость для admin
# manual transitions без _prefix:):
#   pending      — Auto-created при Inquiry. Ждёт ручного review админом
#                  (нужно ли вообще передавать партнёру или прорабатывать
#                  самим как dual-side)
#   forwarded    — Передали партнёру (forwarded_at установлен, agent_notes
#                  содержит channel: «email/TG/звонок»)
#   in_progress  — Партнёр work'ает с лидом (показ запланирован etc.)
#   closed_won   — Сделка закрыта, partner_agency должна нам
#                  final_commission_amount (set при transition)
#   closed_lost  — Отказались / не сложилось
#   stale        — Партнёр не отвечает > 30 days, manual review
#
# Reconciliation reporting в admin UI (Phase 3.4) — sum'ит pending
# commissions per agency.
class Referral < ApplicationRecord
  default_scope { where(deleted_at: nil) }

  belongs_to :inquiry
  belongs_to :partner_agency
  belongs_to :external_listing, optional: true

  STATUSES = %w[pending forwarded in_progress closed_won closed_lost stale].freeze
  CLOSED_STATUSES = %w[closed_won closed_lost].freeze

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :commission_rate,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
            allow_nil: true
  validates :final_commission_amount,
            numericality: { greater_than_or_equal_to: 0 },
            allow_nil: true
  # commission required только когда closed_won — нельзя зафиксировать
  # «выиграли» без указания суммы.
  validate :final_amount_required_when_won

  scope :pending,      -> { where(status: 'pending') }
  scope :forwarded,    -> { where(status: 'forwarded') }
  scope :in_progress,  -> { where(status: 'in_progress') }
  scope :open,         -> { where.not(status: CLOSED_STATUSES) }
  scope :closed,       -> { where(status: CLOSED_STATUSES) }
  scope :closed_won,   -> { where(status: 'closed_won') }
  scope :closed_lost,  -> { where(status: 'closed_lost') }
  scope :for_agency,   ->(agency) { where(partner_agency_id: agency.is_a?(PartnerAgency) ? agency.id : agency) }
  scope :awaiting_settlement, -> { closed_won.where('final_commission_amount IS NULL OR metadata->>\'settled_at\' IS NULL') }
  scope :recent, ->(days = 30) { where('created_at > ?', days.days.ago) }

  # Soft-delete: GDPR + audit-trail consistency.
  def destroy
    update!(deleted_at: Time.current)
  end

  # Lifecycle helpers (UI-friendly).
  def open?
    !CLOSED_STATUSES.include?(status)
  end

  def closed?
    CLOSED_STATUSES.include?(status)
  end

  # State transitions с side-effects (timestamps + audit_log в metadata).
  def forward!(channel:, actor: nil)
    update!(
      status: 'forwarded',
      forwarded_at: Time.current,
      metadata: metadata.merge(
        'forward_channel' => channel,
        'forwarded_by' => actor&.to_s
      )
    )
  end

  def close_won!(amount:, actor: nil)
    update!(
      status: 'closed_won',
      closed_at: Time.current,
      final_commission_amount: amount,
      metadata: metadata.merge('closed_by' => actor&.to_s)
    )
  end

  def close_lost!(reason:, actor: nil)
    update!(
      status: 'closed_lost',
      closed_at: Time.current,
      metadata: metadata.merge(
        'lost_reason' => reason,
        'closed_by' => actor&.to_s
      )
    )
  end

  # Ожидаемая комиссия (для open referrals, ещё не закрытых).
  # Если есть final — берём final; иначе estimate из (listing.price * rate).
  def estimated_commission
    return final_commission_amount.to_f if final_commission_amount.present?
    return 0.0 if commission_rate.blank? || external_listing.blank?
    (external_listing.price.to_f * commission_rate.to_f).round(2)
  end

  private

  # closed_won без фактической ненулевой суммы — бессмысленно для
  # commission reconciliation (settlement → 0₽ нечего settle'ить).
  # Если сделка закрылась без комиссии — это closed_lost, не won.
  def final_amount_required_when_won
    return unless status == 'closed_won'
    return if final_commission_amount.present? && final_commission_amount.to_f.positive?

    errors.add(:final_commission_amount, 'обязательна и > 0 при closed_won (если 0 ₽ — это closed_lost)')
  end
end
