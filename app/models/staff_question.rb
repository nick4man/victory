# frozen_string_literal: true

# Phase 7.5 — Вопрос сотрудника в #ВОПРОС/ОТВЕТ. См. миграцию
# 20260527000700_create_staff_questions.rb для контекста.
class StaffQuestion < ApplicationRecord
  KINDS = ['clarification', 'information', 'escalation'].freeze

  belongs_to :asked_by,     class_name: 'TelegramUser'
  belongs_to :answered_by,  class_name: 'TelegramUser', optional: true
  belongs_to :escalated_to, class_name: 'TelegramUser', optional: true

  enum :kind, {
    clarification: 'clarification', # детали по задаче/лиду; bot answers via tools
    information: 'information', # общее знание/процедура; bot answers from prompt
    escalation: 'escalation' # нужен manager
  }, prefix: true

  validates :question_text, presence: true

  # Phase 9 Iter 2 — DLP. Сотрудник может спросить «номер паспорта Анны?» —
  # ответ потенциально утечёт через question_text/answer_text в БД и в
  # Rails.logger.inspect. Маскируем PII до persist'а. Raw text — ephemeral
  # (только в memory пока вопрос обрабатывается LLM'ом).
  before_validation :redact_pii

  scope :not_deleted,    -> { where(deleted_at: nil) }
  scope :for_asker,      ->(tg_user) { where(asked_by: tg_user) }
  scope :answered,       -> { not_deleted.where.not(answered_at: nil) }
  scope :since,          ->(period) { where(created_at: period..) }
  scope :for_period,     ->(range) { where(created_at: range) }

  default_scope { not_deleted }

  def soft_delete!
    update!(deleted_at: Time.current)
  end

  private

  def redact_pii
    self.question_text = Privacy::TranscriptRedactor.call(question_text) if question_text.present?
    self.answer_text   = Privacy::TranscriptRedactor.call(answer_text)   if answer_text.present?
  end
end
