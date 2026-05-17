# frozen_string_literal: true

# Локальная задача по сделке. Создаётся через /task в TG-боте reply на якорную
# карточку лида; дедлайн дополнительно пробрасывается в Topnlab fc_next_action_at
# кастомное поле через patch_entity.
#
# Связь с CRM-сущностью — через (topnlab_id, topnlab_type). lead_event_id
# опционален: не каждая задача привязана к конкретному LeadEvent (например,
# админ-задача без лида).
class Task < ApplicationRecord
  # Граница «слишком быстрого» ack — если completed_at < 60s после assigned_at,
  # помечаем suspicious_flag=true для weekly review (см. Phase 7.6 KPI).
  # Не блокирует completion — surface-only сигнал.
  SUSPICIOUS_WINDOW = 60.seconds

  # === Associations ===
  belongs_to :lead_event, optional: true
  belongs_to :assignee,   class_name: 'TelegramUser', optional: true
  belongs_to :created_by, class_name: 'TelegramUser', optional: true
  belongs_to :task_batch, optional: true

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

  # Phase 7.3 — priority / kind / acked_method enums.
  enum :priority, {
    low: 'low',
    normal: 'normal',
    high: 'high',
    urgent: 'urgent'
  }, prefix: true

  enum :kind, {
    call: 'call',         # звонок клиенту
    show: 'show',         # показ объекта
    document: 'document', # договор/документы/CRM-карточка
    admin: 'admin',       # внутренняя координация
    other: 'other'        # прочее
  }, prefix: true

  enum :acked_method, {
    button: 'button',     # inline-кнопка [✅ Выполнено]
    command: 'command',   # /done <id>
    reaction: 'reaction'  # ✅ emoji-реакция
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
  scope :overdue,   -> { status_open.where(due_at: ...Time.current) }
  scope :due_today, -> { status_open.where(due_at: Time.current.all_day) }
  scope :for_lead,  ->(lead_event) { where(lead_event: lead_event) }
  scope :for_assignee, ->(tg_user) { where(assignee_id: tg_user.id) }
  scope :suspicious,   -> { where(suspicious_flag: true) }

  # === Phase 7.3 — multi-modal completion ack ===
  # @param acked_method [String] 'button' | 'command' | 'reaction'
  # @return [self]
  def mark_completed!(acked_method:)
    now = Time.current
    assign_attributes(
      status: 'done',
      completed_at: now,
      first_acked_at: first_acked_at || now,
      acked_method: acked_method.to_s,
      suspicious_flag: suspicious_completion?(now)
    )
    save!
    self
  end

  # Маркер «работаю над задачей» — [▶ В работе] button.
  def mark_started!
    now = Time.current
    assign_attributes(
      started_at: started_at || now,
      first_acked_at: first_acked_at || now
    )
    save!
    self
  end

  # Длительность от назначения до выполнения (seconds). nil если не closed.
  def completion_duration_sec
    return nil unless completed_at && assigned_at

    (completed_at - assigned_at).to_i
  end

  private

  def suspicious_completion?(now)
    return false if assigned_at.blank?
    return true  if (now - assigned_at) < SUSPICIOUS_WINDOW

    # call-task без lead.first_contact_at → подозрение (задача «позвонить»
    # но в карточке нет факта первого контакта) — surface-only.
    if kind_call? && lead_event.respond_to?(:first_contact_at) && lead_event.first_contact_at.blank?
      return true
    end

    false
  end
end
