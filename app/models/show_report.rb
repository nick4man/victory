# frozen_string_literal: true

# BOTTLENECK — факт показа с обратной связью покупателя. См. миграцию 20260911100100.
class ShowReport < ApplicationRecord
  # === Associations ===
  belongs_to :lead_event
  belongs_to :property, optional: true
  belongs_to :conducted_by, class_name: 'TelegramUser' # кто показывал
  belongs_to :reported_by,  class_name: 'TelegramUser' # кто надиктовал/написал

  # === Enums (правило 2 CLAUDE.md — prefix обязателен) ===
  enum :outcome, {
    thinking: 'thinking',            # думают / взяли паузу
    declined: 'declined',            # отказ
    second_show: 'second_show',      # хотят второй показ
    bargain: 'bargain',              # назвали цену / торг
    deposit_intent: 'deposit_intent' # готовы к задатку
  }, prefix: true

  OUTCOME_LABELS = {
    'thinking'       => '🤔 Думают',
    'declined'       => '❌ Отказ',
    'second_show'    => '🔁 Второй показ',
    'bargain'        => '💬 Торг',
    'deposit_intent' => '✍️ Готовы к задатку'
  }.freeze

  enum :status, {
    pending_confirm: 'pending_confirm', # ждёт подтверждения в DM
    confirmed: 'confirmed',             # подтверждён — учитывается в метриках
    cancelled: 'cancelled',             # отменён
    expired: 'expired'                  # висел в pending > 1 часа, снят кроном
  }, prefix: true

  enum :source, {
    voice: 'voice', # голосовое
    text: 'text'    # /show текстом
  }, prefix: true

  # === Soft-delete (правило 1) ===
  scope :not_deleted, -> { where(deleted_at: nil) }
  default_scope { not_deleted }

  # === Validations ===
  validates :conducted_at, presence: true

  # === Scopes ===
  scope :confirmed_in, ->(range) { status_confirmed.where(conducted_at: range) }
  scope :for_property, ->(property) { where(property_id: property.id) }
  scope :expired_candidates, ->(older_than:) { status_pending_confirm.where(created_at: ...older_than) }

  def confirm!
    return self unless status_pending_confirm?

    update!(status: 'confirmed')
    self
  end

  def cancel!
    return self unless status_pending_confirm?

    update!(status: 'cancelled')
    self
  end

  # BOTTLENECK — симметрично TaskBatch: неподтверждённый отчёт не живёт вечно.
  # Иначе «показов без отчёта» в недельной сводке показывает показ как
  # неотчитанный, хотя отчёт надиктован и ждёт одной кнопки.
  def expire!
    return self unless status_pending_confirm?

    update!(status: 'expired')
    self
  end

  def conducted_by_director?
    conducted_by.role_director? || conducted_by.role_admin?
  end

  def outcome_label
    OUTCOME_LABELS[outcome] || outcome
  end

  def objections_list
    Array(objections).map { |o| o.to_s.strip.downcase }.compact_blank
  end

  # Превью даёт одну кнопку «показывал(а) я / руководитель» — переключатель
  # между тем, кто диктует, и директором. Третьего варианта в агентстве нет.
  def toggle_conductor!(reporter:, director:)
    target = conducted_by_id == director&.id ? reporter : director
    return self if target.nil?

    update!(conducted_by: target)
    self
  end
end
