# frozen_string_literal: true

# Phase 4A — Required document for a deal (Phase 4 master-plan).
#
# Design:
#   • Per-deal checklist (lead_event_id) ИЛИ per-property (lead_event_id NULL,
#     property_id set) — например EGRN required для listing до того как есть
#     active inquiry.
#   • 6-state lifecycle: not_requested → requested → received → verified
#                                                              → approved | rejected
#   • Per-kind SLA (см. SLA_SECONDS) — different urgency tiers
#   • Dependency graph (DEPENDS_ON) — passport_main received triggers
#     passport_registration auto-create (DocumentChecklist::Builder applies)
#   • Soft-delete via deleted_at (CLAUDE.md rule 1)
#   • Enums с _prefix: true (CLAUDE.md rule 2)
#
# Linkage to Phase 4G AI classification:
#   ClientDocument (A6 intake) → AutoMatchToRequirement → DocumentRequirement
#   с received_via_client_document_id = OCR'd photo.
class DocumentRequirement < ApplicationRecord
  # === Associations ===
  belongs_to :lead_event, optional: true
  belongs_to :property, optional: true
  belongs_to :requested_by, class_name: 'TelegramUser', optional: true
  belongs_to :verified_by,  class_name: 'TelegramUser', optional: true
  belongs_to :approved_by,  class_name: 'TelegramUser', optional: true
  belongs_to :received_via_client_document,
             class_name: 'ClientDocument', optional: true

  # === Enums (CLAUDE.md rule 2 — _prefix обязателен) ===
  # 15 kinds — comprehensive РФ-real-estate document taxonomy.
  # Когда добавляешь новый kind — sync с:
  #   • SLA_SECONDS (per-kind SLA в секундах)
  #   • DEPENDS_ON (dependency graph)
  #   • RU_LABELS (для UI / /doc reply / reminders)
  #   • lib/document_checklist/templates/*.yml (per-deal-type)
  enum :kind, {
    passport_main: 'passport_main',                 # паспорт (страницы 2-3)
    passport_registration: 'passport_registration', # паспорт прописка (страницы 14-15)
    snils: 'snils',
    inn: 'inn',
    egrn_excerpt: 'egrn_excerpt',                   # выписка из ЕГРН
    cadastral_passport: 'cadastral_passport',       # кадастровый паспорт
    contract_sale: 'contract_sale',                 # договор купли-продажи
    mortgage_approval: 'mortgage_approval',         # одобрение банка
    spousal_consent: 'spousal_consent',             # нотариальное согласие супруга
    power_of_attorney: 'power_of_attorney',         # доверенность
    marriage_certificate: 'marriage_certificate',
    birth_certificate: 'birth_certificate',         # свидетельство о рождении (для несовершеннолетних)
    appraisal_report: 'appraisal_report',           # оценочный отчёт
    insurance_policy: 'insurance_policy',           # ипотечное страхование
    marital_status: 'marital_status',               # справка о семейном положении
    other: 'other'
  }, prefix: true

  enum :status, {
    not_requested: 'not_requested', # есть в template, но agent ещё не запросил
    requested: 'requested',         # agent запросил клиента
    received: 'received',           # клиент прислал, agent не verified
    verified: 'verified',           # agent проверил OCR/structure (физический documents OK)
    approved: 'approved',           # legal/manager review passed (Phase 5+ extension)
    rejected: 'rejected'            # отклонён (с reason в metadata)
  }, prefix: true

  # === Per-kind SLA (seconds) — different urgency tiers. ===
  # passport — instant (1 day). EGRN — typical 5 days for госуслуги.
  # contract_sale — 14 days (drafting + lawyer + signing).
  SLA_SECONDS = {
    'passport_main'         => 1.day.to_i,
    'passport_registration' => 2.days.to_i,
    'snils'                 => 2.days.to_i,
    'inn'                   => 2.days.to_i,
    'egrn_excerpt'          => 5.days.to_i,
    'cadastral_passport'    => 5.days.to_i,
    'contract_sale'         => 14.days.to_i,
    'mortgage_approval'     => 14.days.to_i,
    'spousal_consent'       => 5.days.to_i,
    'power_of_attorney'     => 5.days.to_i,
    'marriage_certificate'  => 2.days.to_i,
    'birth_certificate'     => 2.days.to_i,
    'appraisal_report'      => 7.days.to_i,
    'insurance_policy'      => 7.days.to_i,
    'marital_status'        => 3.days.to_i,
    'other'                 => 5.days.to_i
  }.freeze

  # === Dependency graph: kind → required prerequisites ===
  # Triggers cascade в DocumentChecklist::Builder.recompute(lead).
  # Например, при создании contract_sale автоматически создаются (если ещё нет):
  # egrn_excerpt + passport_main.
  DEPENDS_ON = {
    'passport_registration' => ['passport_main'],
    'contract_sale'         => %w[egrn_excerpt passport_main],
    'mortgage_approval'     => %w[passport_main snils inn],
    'spousal_consent'       => ['marriage_certificate']
  }.freeze

  # === Russian labels — UI/reply/reminder text. ===
  RU_LABELS = {
    'passport_main'         => 'паспорт (основной)',
    'passport_registration' => 'паспорт (прописка)',
    'snils'                 => 'СНИЛС',
    'inn'                   => 'ИНН',
    'egrn_excerpt'          => 'выписка из ЕГРН',
    'cadastral_passport'    => 'кадастровый паспорт',
    'contract_sale'         => 'договор купли-продажи',
    'mortgage_approval'     => 'одобрение банка',
    'spousal_consent'       => 'согласие супруга',
    'power_of_attorney'     => 'доверенность',
    'marriage_certificate'  => 'свидетельство о браке',
    'birth_certificate'     => 'свидетельство о рождении',
    'appraisal_report'      => 'оценочный отчёт',
    'insurance_policy'      => 'страховой полис',
    'marital_status'        => 'справка о семейном положении',
    'other'                 => 'другой документ'
  }.freeze

  # === Shorthand aliases для /doc parser (Phase 4B). ===
  # Например /doc pass+ → passport_main received. /doc egrn? → egrn_excerpt requested.
  KIND_ALIASES = {
    'pass' => 'passport_main', 'passport' => 'passport_main',
    'reg'  => 'passport_registration',
    'snils' => 'snils', 'inn' => 'inn',
    'egrn' => 'egrn_excerpt', 'выписка' => 'egrn_excerpt',
    'cadastral' => 'cadastral_passport', 'kadastr' => 'cadastral_passport',
    'contract' => 'contract_sale', 'договор' => 'contract_sale',
    'mortgage' => 'mortgage_approval', 'ипотека' => 'mortgage_approval',
    'spouse' => 'spousal_consent', 'супруг' => 'spousal_consent',
    'poa' => 'power_of_attorney', 'доверенность' => 'power_of_attorney',
    'marriage' => 'marriage_certificate', 'брак' => 'marriage_certificate',
    'birth' => 'birth_certificate',
    'appraisal' => 'appraisal_report', 'оценка' => 'appraisal_report',
    'insurance' => 'insurance_policy', 'страховка' => 'insurance_policy',
    'marital' => 'marital_status'
  }.freeze

  # === Soft-delete (CLAUDE.md rule 1) ===
  scope :not_deleted, -> { where(deleted_at: nil) }
  default_scope { not_deleted }

  def soft_destroy!
    update!(deleted_at: Time.current)
  end

  # === Scopes ===
  scope :open, -> { where(status: %w[not_requested requested received]) }
  scope :final, -> { where(status: %w[approved rejected]) }
  scope :overdue, lambda {
    where(status: %w[requested received])
      .where('requested_at IS NOT NULL AND requested_at < ?', Time.current - 24.hours)
  }

  # === Lifecycle helpers — set timestamps + actor ===
  def request!(by:)
    update!(status: 'requested', requested_at: requested_at || Time.current, requested_by: by)
  end

  def receive!(via_client_document: nil)
    update!(
      status: 'received',
      received_at: Time.current,
      received_via_client_document: via_client_document
    )
  end

  def verify!(by:)
    update!(status: 'verified', verified_at: Time.current, verified_by: by)
  end

  def approve!(by:)
    update!(status: 'approved', approved_at: Time.current, approved_by: by)
  end

  def reject!(by:, reason: nil)
    new_meta = metadata.merge('rejected_by' => by&.mention, 'rejection_reason' => reason.to_s.presence)
    update!(status: 'rejected', rejected_at: Time.current, metadata: new_meta)
  end

  # === SLA helpers ===
  # Returns seconds since requested_at OR nil если ещё не requested.
  def time_since_requested
    return nil if requested_at.blank?

    Time.current - requested_at
  end

  # Per-kind SLA — может быть overridden через sla_seconds column для кастом.
  def effective_sla
    sla_seconds.presence || SLA_SECONDS[kind] || SLA_SECONDS['other']
  end

  # Overdue factor: > 1.0 = просрочка, < 1.0 = в SLA. nil если не requested.
  # Используется Phase 4F SLA assessor для ramping reminders (1.0/2.0/3.0 cutoffs).
  def overdue_factor
    elapsed = time_since_requested
    return nil if elapsed.nil?

    sla = effective_sla.to_f
    return nil if sla.zero?

    elapsed / sla
  end

  def overdue?
    factor = overdue_factor
    factor && factor >= 1.0
  end

  def ru_label
    RU_LABELS[kind] || kind
  end
end
