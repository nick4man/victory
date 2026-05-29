# frozen_string_literal: true

# Phase 7.4 — Pinned digest message в #ДИСПЕТЧЕРСКАЯ. См. миграцию
# 20260527000600_create_daily_digests.rb для контекста.
class DailyDigest < ApplicationRecord
  validates :date,          presence: true
  validates :tg_chat_id,    presence: true
  validates :tg_message_id, presence: true

  scope :not_deleted, -> { where(deleted_at: nil) }
  scope :for_date,    ->(date) { not_deleted.where(date: date) }
  scope :active,      -> { not_deleted.where(archived_at: nil) }
  scope :stale,       ->(before: Date.current) { active.where(date: ...before) }

  default_scope { not_deleted }

  def archived?
    archived_at.present?
  end

  def archive!
    update!(archived_at: Time.current)
  end
end
