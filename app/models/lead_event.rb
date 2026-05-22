# frozen_string_literal: true

# Состояние конвейера обработки лида в Telegram-боте АН.
# Один LeadEvent = один лид + его представление в TG-чате (карточка-якорь в
# текущем специализированном топике + опциональный тизер в #СДЕЛКА).
#
# Жизненный цикл:
#   1. Lead::Intake создаёт запись с anchor_topic_key='dispatcher'
#   2. /route переносит anchor в специализированный топик (apartments, mortgage, …)
#   3. /assign фиксирует assigned_to + assigned_at + first SLA-таймер
#   4. /stage обновляет current_stage; при 'contract'/'deal' создаётся deal_mirror в #СДЕЛКА
#   5. /close выставляет closed_at + current_stage='closed_won'/'closed_lost'
class LeadEvent < ApplicationRecord
  SOURCES = ['site_form', 'site_valuation', 'site_mortgage', 'tg_dm', 'manual', 'crm_webhook'].freeze
  STAGES  = ['new', 'first_contact', 'show', 'contract', 'deal', 'closed_won', 'closed_lost'].freeze
  TOPIC_KEYS = [
    'dispatcher',
    'apartments',
    'houses',
    'lots',
    'commercial',
    'rent',
    'mortgage',
    'appraisal',
    'taxes',
    'insurance',
    'escrow',
    'deal'
  ].freeze

  belongs_to :lead_ref, polymorphic: true
  belongs_to :assigned_to, class_name: 'TelegramUser', optional: true
  # Iter 59 — кто из staff выполнил действие. assigned_to vs assigned_by:
  # «assigned_to» — кому назначили, «assigned_by» — кто назначил.
  belongs_to :assigned_by, class_name: 'TelegramUser', optional: true
  belongs_to :routed_by,   class_name: 'TelegramUser', optional: true

  validates :source,           inclusion: { in: SOURCES }
  validates :current_stage,    inclusion: { in: STAGES }
  validates :anchor_topic_key, inclusion: { in: TOPIC_KEYS }
  validates :tg_chat_id, presence: true

  scope :open,     -> { where.not(current_stage: ['closed_won', 'closed_lost']) }
  scope :closed,   -> { where(current_stage: ['closed_won', 'closed_lost']) }
  scope :for_agent, ->(tg_user) { where(assigned_to: tg_user) }
  scope :awaiting_first_contact, lambda {
    where(first_contact_at: nil)
      .where.not(assigned_at: nil)
      .where.not(current_stage: ['closed_won', 'closed_lost'])
  }
  scope :in_topic, ->(key) { where(anchor_topic_key: key) }
  # Iter 59 — director self-audit: «какие лиды я назначил / направил за период»
  scope :assigned_by_tg, ->(tg_user) { where(assigned_by_id: tg_user.id) }
  scope :routed_by_tg,   ->(tg_user) { where(routed_by_id: tg_user.id) }
  # Aggregation окно: используем updated_at — фактически последняя mutation
  # (route/assign/stage переход). created_at не годится: лид создан днём назад,
  # routed сегодня — попадёт в today.
  scope :updated_in, ->(range) { where(updated_at: range) }

  # Phase 16 — staff_test scopes (default scope не делаем, чтобы не сломать
  # admin/debug queries. Caller сам решает .real или .staff_test).
  scope :real,       -> { where(staff_test: false) }
  scope :staff_test_only, -> { where(staff_test: true) }

  # Phase 16 — auto-tag через эвристики (StaffSubmissionDetector).
  # Читаем name/email/phone из metadata (где Lead::Intake их кладёт).
  before_validation :detect_staff_test_submission, on: :create

  def open?
    !closed?
  end

  def closed?
    ['closed_won', 'closed_lost'].include?(current_stage)
  end

  def assigned?
    assigned_to_id.present?
  end

  # Telegram t.me deep-link to the current anchor message — для тизеров и SLA-пингов.
  # Два формата (см. Telegram client behavior):
  #   • Forum topic: t.me/c/<chat-без-100>/<thread_id>/<message_id>
  #   • General / non-forum group: t.me/c/<chat-без-100>/<message_id>
  # tg_chat_id для supergroup негативный с префиксом -100; в URL без него.
  def anchor_url
    return nil if anchor_message_id.blank? || tg_chat_id.blank?

    chat = tg_chat_id.to_s.delete_prefix('-100')
    if anchor_thread_id.present?
      "https://t.me/c/#{chat}/#{anchor_thread_id}/#{anchor_message_id}"
    else
      # General topic: TG не использует thread_id в URL (или dropped == 1).
      "https://t.me/c/#{chat}/#{anchor_message_id}"
    end
  end

  # Phase 12 Iter 39 — anti-bloat helper для metadata-history arrays.
  # До этого фикса /note + AnchorMigrator + /stage history append'или
  # entries в metadata jsonb без cap'а. Лид с 50 reassignments + 100 notes
  # → metadata 200+ KB → slow queries, slow LeadEvent#update!.
  #
  # @param key [String] — например 'notes', 'routing_history', 'stage_history'
  # @param entry [Hash] — pre-built hash для append
  # @param cap [Integer] — оставить last(cap) entries (default 50)
  # @return [Array] обрезанный массив (caller сам делает update! с metadata.merge)
  HISTORY_DEFAULT_CAPS = {
    'notes' => 50,
    'routing_history' => 20,
    'stage_history' => 20,
    'dispatch_failures' => 5,
    'crm_sync_errors' => 5 # Phase 13 Iter 47 — last 5 CRM-sync errors для pattern detection
  }.freeze

  def append_history(key:, entry:, cap: nil)
    cap ||= HISTORY_DEFAULT_CAPS[key.to_s] || 50
    existing = Array(metadata[key.to_s])
    existing << entry
    existing.last(cap)
  end

  private

  # Phase 16 — auto-tag через StaffSubmissionDetector. Lead::Intake кладёт
  # name/email/phone в metadata. Если linked Inquiry уже tag'нут — копируем
  # его decision (consistency между linked records).
  def detect_staff_test_submission
    return if staff_test # уже выставлен manually

    # Если parent Inquiry уже tag'нут — наследуем
    if lead_ref.is_a?(Inquiry) && lead_ref.staff_test
      self.staff_test = true
      self.staff_test_matched_by = "inherited_from_inquiry##{lead_ref.id}"
      return
    end

    meta = metadata || {}
    result = StaffSubmissionDetector.detect(
      email: meta['email'],
      phone: meta['phone'],
      name:  meta['name'],
      tg_user_id: meta['tg_user_id']
    )
    self.staff_test = result.staff_test
    self.staff_test_matched_by = result.matched_by
  end
end
