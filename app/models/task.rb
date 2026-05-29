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

  # === Phase 7.4 — auto-refresh pinned digest on lifecycle changes ===
  # Срабатывает: новая задача (assigned_at set) и переход в done. Канцелы
  # игнорируем — они уходят из digest при следующем refresh естественно.
  after_commit :refresh_dispatcher_digest, on: [:create, :update]

  # === Scopes ===
  scope :overdue,   -> { status_open.where(due_at: ...Time.current) }
  scope :due_today, -> { status_open.where(due_at: Time.current.all_day) }
  scope :for_lead,  ->(lead_event) { where(lead_event: lead_event) }
  scope :for_assignee, ->(tg_user) { where(assignee_id: tg_user.id) }
  scope :suspicious,   -> { where(suspicious_flag: true) }
  # Iter 59 — director self-audit: «какие задания я создал сегодня/на неделе»
  scope :created_by_tg, ->(tg_user) { where(created_by_id: tg_user.id) }
  scope :created_in,    ->(range)   { where(created_at: range) }

  # === Iter 60 — attachments (photo/document refs) ===
  # JSONB array: [{ tg_file_id:, nc_url:, kind:, uploaded_at:, uploaded_by: }]
  # Используем хелпер чтобы не дублировать deep_stringify_keys + last(20) cap.
  def append_attachment!(tg_file_id:, nc_url:, kind: 'image', uploaded_by: nil)
    entry = {
      'tg_file_id' => tg_file_id.to_s,
      'nc_url' => nc_url.to_s,
      'kind' => kind.to_s,
      'uploaded_at' => Time.current.iso8601,
      'uploaded_by' => uploaded_by
    }.compact
    update!(attachments: (Array(attachments) + [entry]).last(20))
  end

  # === Phase 7.3 — multi-modal completion ack ===
  # Phase 9 Iter 3: idempotent через transaction + reload check —
  # параллельные button/command/reaction вызовы → single completion.
  # @param acked_method [String] 'button' | 'command' | 'reaction'
  # @return [self]
  def mark_completed!(acked_method:)
    Task.transaction do
      reload if persisted?
      return self if status_done?

      now = Time.current
      assign_attributes(
        status: 'done',
        completed_at: now,
        first_acked_at: first_acked_at || now,
        acked_method: acked_method.to_s,
        suspicious_flag: suspicious_completion?(now)
      )
      save!
    end
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

  # Phase 9 Iter 9 — Async digest refresh через Sidekiq + Redis-lock debounce.
  # Раньше синхронный edit_message_text → race на parallel updates.
  # Теперь — job с 1s debounce window, 5 параллельных updates → 1 TG call.
  def refresh_dispatcher_digest
    return if Thread.current[:skip_dispatcher_digest_refresh]
    return if assigned_at.blank? # задачи без assignment — не в digest

    DispatcherDigestRefreshJob.perform_async
  rescue StandardError => e
    Rails.logger.warn("[Task#refresh_dispatcher_digest] #{e.class}: #{e.message}")
  end

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
