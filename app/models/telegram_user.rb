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

  # Phase 14 Iter 57 — резолвер identifier'а из voice-intake / LLM payload.
  # Поддерживает два формата:
  #   • "@username" / "username" — обычный TG handle (case-insensitive)
  #   • "id:14" — internal DB id для сотрудников без tg_username
  #     (приватная настройка профиля в TG; мы её не можем изменить).
  # До этого фикса staff без tg_username были невидимы LLM в TaskExtractor
  # → задачи на них уходили в uncertainties.
  ID_TOKEN_RE = /\Aid:(\d+)\z/i

  def self.resolve_identifier(token)
    return nil if token.blank?

    s = token.to_s.strip
    if (m = s.match(ID_TOKEN_RE))
      find_by(id: m[1].to_i)
    else
      find_by_username(s)
    end
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

  # Phase 13 Iter 41 — единый predicate для manager-level commands.
  # До этого фикса `manager_only` гейт проверял ТОЛЬКО legacy `is_manager` boolean.
  # Директор с role='director' но is_manager=false (например, добавленный
  # через auto_discovery без явного /promote ... manager) блокировался от
  # /assign, /lead, /promote, /demote, /reassign, /reopen, /deactivate.
  # Helper расширяет: directors + admins считаются manager-equivalent.
  def manager_or_director?
    is_manager? || role_director? || role_admin?
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

    # Phase 14 Iter 54 — wrap в with_lock чтобы parallel inbound messages
    # (особенно serial TG-rapid-fire) не race'или username / dm_chat_id.
    # До фикса: handler1 видит stored='old' + new='new', handler2 параллельно
    # видит stored='old' + new='old_reverted'. Порядок update_columns →
    # final state может быть 'new' вместо 'old_reverted'.
    #
    # with_lock + reload даёт atomic check-and-set — handler2 видит уже
    # обновлённое handler1 state, делает correct delta.
    #
    # На hot path (каждое TG-сообщение) — но lock pessimistic per-row, не
    # блокирует other users. Trade-off OK для correctness.
    result = false
    dm_chat_id_just_set = false
    with_lock do
      reload
      changes = {}
      changes[:tg_username] = from['username'] if from['username'].present? && from['username'] != tg_username
      changes[:first_name]  = from['first_name'] if from['first_name'].present? && first_name.blank?
      changes[:last_name]   = from['last_name']  if from['last_name'].present?  && last_name.blank?
      if chat['type'] == 'private' && chat['id'].present? && chat['id'] != dm_chat_id
        # Iter 58 — флаг для post-lock sync TG-меню. Только переход
        # blank→present триггерит sync (а не каждый DM-апдейт).
        dm_chat_id_just_set = dm_chat_id.blank?
        changes[:dm_chat_id] = chat['id']
      end
      changes[:last_seen_at] = Time.current

      next if changes.empty?

      # update_columns — skip validations/callbacks (heavy use в InboundProcessor)
      update_columns(changes) # rubocop:disable Rails/SkipsModelValidations
      result = true
    end

    # Iter 58 — после lock release: первый /start от сотрудника даёт нам
    # dm_chat_id → сразу регистрируем native /-меню в его DM по его role-tier.
    # Soft-fail: sync issue не должна ломать InboundProcessor flow.
    if dm_chat_id_just_set
      begin
        Telegram::WorkBot::CommandsMenuSync.new.sync_for_user!(self)
      rescue StandardError => e
        Rails.logger.warn("[CommandsMenuSync] touch_from_message! sync skip for tg_user=#{id}: #{e.class} #{e.message}")
      end
    end

    result
  end
end
