# frozen_string_literal: true

# Локальная задача по сделке. Создаётся через /task в TG-боте reply на якорную
# карточку лида; дедлайн дополнительно пробрасывается в Topnlab fc_next_action_at
# кастомное поле через patch_entity.
#
# Связь с CRM-сущностью — через (topnlab_id, topnlab_type). lead_event_id
# опционален: не каждая задача привязана к конкретному LeadEvent (например,
# админ-задача без лида).
class Task < ApplicationRecord
  # === Associations ===
  belongs_to :lead_event, optional: true
  belongs_to :assignee,   class_name: 'TelegramUser', optional: true
  belongs_to :created_by, class_name: 'TelegramUser', optional: true

  # === Enums (см. CLAUDE.md правило 2 — _prefix обязателен) ===
  enum :status, {
    open: 'open',     # активная
    done: 'done',     # выполнена
    canceled: 'canceled' # отменена
  }, prefix: true

  enum :topnlab_type, {
    realty: 'realty',
    order: 'order'
  }, prefix: true

  # === Soft-delete (см. CLAUDE.md правило 1 — никакого paranoia gem) ===
  scope :not_deleted, -> { where(deleted_at: nil) }
  default_scope { not_deleted }

  def soft_destroy!
    update!(deleted_at: Time.current)
  end

  # === Validations ===
  validates :title, presence: true

  # === Scopes ===
  scope :overdue,     -> { status_open.where(due_at: ...Time.current) }
  scope :due_today,   -> { status_open.where(due_at: Time.current.all_day) }
  scope :for_lead,    ->(lead_event) { where(lead_event: lead_event) }
end
