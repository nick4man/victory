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

  scope :not_deleted,    -> { where(deleted_at: nil) }
  scope :for_asker,      ->(tg_user) { where(asked_by: tg_user) }
  scope :answered,       -> { not_deleted.where.not(answered_at: nil) }
  scope :since,          ->(period) { where(created_at: period..) }
  scope :for_period,     ->(range) { where(created_at: range) }

  default_scope { not_deleted }

  def soft_delete!
    update!(deleted_at: Time.current)
  end
end
