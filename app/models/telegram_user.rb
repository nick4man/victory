# frozen_string_literal: true

# Сотрудник АН, привязанный к рабочему Telegram-боту.
# Сопоставляет Telegram user_id с Topnlab user_id — нужно для назначения лидов
# через /call/main/transferClient/ (Topnlab принимает email агента).
#
# Создаётся командой `/whoami email@victory.ru`:
#   1. Бот ищет email в Topnlab::Client#get_users
#   2. Шлёт 6-значный код на email через TelegramAuthMailer
#   3. Агент в DM боту отправляет код → запись создаётся / активируется
class TelegramUser < ApplicationRecord
  STATUSES = ['active', 'inactive', 'blocked'].freeze

  # Phase 7.1 — enum-роль для voice-intake авторизации (см. CLAUDE.md правило 2).
  # `is_manager` boolean остаётся для legacy кода (managers/manager_only),
  # role даёт более точную градацию: director > manager > agent.
  enum :role, {
    agent: 'agent',        # обычный сотрудник
    manager: 'manager',    # руководитель отдела (legacy ↔ is_manager=true)
    director: 'director',  # директор АН (Оксана) — может voice-distribute
    admin: 'admin'         # технический admin
  }, prefix: true

  has_many :assigned_lead_events,
           class_name: 'LeadEvent',
           foreign_key: :assigned_to_id,
           dependent: :nullify,
           inverse_of: :assigned_to

  validates :tg_user_id, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  scope :active,    -> { where(status: 'active') }
  scope :managers,  -> { where(is_manager: true) }
  scope :directors, -> { where(role: 'director') }

  # @param tg_username [String] @username без префикса (как Telegram возвращает в from.username)
  def self.find_by_username(tg_username)
    return nil if tg_username.blank?

    where('LOWER(tg_username) = ?', tg_username.to_s.downcase.sub(/\A@/, '')).first
  end

  # @param email [String]
  def self.find_by_topnlab_email(email)
    return nil if email.blank?

    where('LOWER(email) = ?', email.to_s.downcase.strip).first
  end

  def display_name
    [first_name, last_name].compact_blank.join(' ').presence || tg_username.presence || "tg:#{tg_user_id}"
  end

  def mention
    tg_username.present? ? "@#{tg_username}" : display_name
  end

  def linked_to_crm?
    topnlab_user_id.present? && email.present?
  end

  # Phase 7.1 — может ли пользователь распределять задачи голосом.
  # director > admin > legacy is_manager (для backward-compat: тех, кого ещё
  # не апгрейднули до role=director, но кто формально руководит АН).
  def can_voice_distribute?
    role_director? || role_admin?
  end

  def touch_seen!
    update_column(:last_seen_at, Time.current)
  end
end
