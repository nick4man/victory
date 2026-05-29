# frozen_string_literal: true

# Phase 7.2 — Контейнер пакета задач от voice-сообщения Оксаны.
# См. миграцию 20260527000300_create_task_batches.rb для контекста lifecycle.
class TaskBatch < ApplicationRecord
  STATUSES = ['pending_confirm', 'confirmed', 'cancelled', 'expired'].freeze
  SOURCES  = ['voice', 'text', 'manual'].freeze

  belongs_to :created_by, class_name: 'TelegramUser'
  has_many :tasks, dependent: :nullify # связь tasks ← task_batch_id (Phase 7.3 migration)

  enum :status, {
    pending_confirm: 'pending_confirm',
    confirmed: 'confirmed',
    cancelled: 'cancelled',
    expired: 'expired'
  }, prefix: true

  enum :source, { voice: 'voice', text: 'text', manual: 'manual' }, prefix: true

  scope :not_deleted, -> { where(deleted_at: nil) }
  scope :pending,     -> { not_deleted.where(status: 'pending_confirm') }
  scope :expired_candidates, lambda { |older_than: 1.hour.ago|
    pending.where(created_at: ...older_than)
  }

  default_scope { not_deleted }

  # @return [Array<Hash>] список задач из parsed_payload (with symbol keys)
  def tasks_payload
    Array(parsed_payload.is_a?(Hash) ? parsed_payload['tasks'] : nil).map do |t|
      t.transform_keys(&:to_sym)
    end
  end

  def soft_delete!
    update!(deleted_at: Time.current)
  end

  def confirm!
    update!(status: 'confirmed', confirmed_at: Time.current)
  end

  def cancel!
    update!(status: 'cancelled', cancelled_at: Time.current)
  end

  def expire!
    update!(status: 'expired', expired_at: Time.current)
  end
end
