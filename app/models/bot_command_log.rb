# frozen_string_literal: true

# Минимальный аудит-лог команд TG-бота. Пишется из Router/CallbacksRouter при
# обработке каждой команды (включая anon-пользователей — поэтому tg_user_id, не FK).
# Метрики adoption: `BotCommandLog.where('created_at > ?', 1.day.ago).group(:command).count`.
class BotCommandLog < ApplicationRecord
  RESULTS = ['ok', 'error', 'forbidden', 'unknown_command'].freeze

  validates :tg_user_id, presence: true
  validates :command,    presence: true

  # Лог-only; updated_at не нужен.
  self.record_timestamps = false
  before_create { |r| r.created_at ||= Time.current }

  scope :recent,        -> { order(created_at: :desc) }
  scope :for_command,   ->(cmd) { where(command: cmd) }
  scope :errors,        -> { where(result: 'error') }
  scope :for_user,      ->(tg_user_id) { where(tg_user_id: tg_user_id) }
end
