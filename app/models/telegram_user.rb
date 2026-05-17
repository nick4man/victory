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

  scope :active,     -> { where(status: 'active') }
  scope :managers,   -> { where(is_manager: true) }
  scope :directors,  -> { where(role: 'director') }
  # assignable=true (default) + active — кандидаты для picker'а [👤 Назначить]
  # и LLM-extract assignee match. Опт-аут — для admin/dev users (не полевые агенты).
  scope :assignable, -> { active.where(assignable: true) }

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

  # Phase 7.3+ — обновить метаданные из TG-сообщения. Используется в
  # InboundProcessor когда от known TelegramUser приходит апдейт — TG может
  # дать новый username (юзер сменил handle), first_name (профиль обновил)
  # и dm_chat_id (если это первое сообщение в DM боту — после этого TG
  # позволяет нам инициировать DM).
  #
  # @param msg [Hash] TG message payload (msg.from + msg.chat)
  # @return [Boolean] true если что-то поменялось и было сохранено
  def touch_from_message!(msg)
    from = msg['from'] || {}
    chat = msg['chat'] || {}

    changes = {}
    changes[:tg_username] = from['username'] if from['username'].present? && from['username'] != tg_username
    changes[:first_name]  = from['first_name'] if from['first_name'].present? && first_name.blank?
    changes[:last_name]   = from['last_name']  if from['last_name'].present?  && last_name.blank?
    if chat['type'] == 'private' && chat['id'].present? && chat['id'] != dm_chat_id
      changes[:dm_chat_id] =
        chat['id']
    end
    changes[:last_seen_at] = Time.current

    return false if changes.empty?

    update_columns(changes) # update_columns — skip validations/callbacks (heavy use в InboundProcessor)
    true
  end
end
