# frozen_string_literal: true

# Карточка для выгрузки в CRM Topnlab после ручной модерации.
#
# Путь один для сайта и Telegram: ответственный связался с клиентом →
# дозаполнил карточку → машинная проверка → модерация → выгрузка. Статус
# меняет только CrmCards::Workflow — там же права и журнал.
#
# payload — значения полей по CrmCards::Schema, ключи — строки, значения уже
# нормализованы CrmCards::FieldValue. check_errors — итог CrmCards::Checker.
class CrmCard < ApplicationRecord
  belongs_to :lead_event, optional: true
  belongs_to :author,   class_name: 'TelegramUser'
  belongs_to :reviewer, class_name: 'TelegramUser', optional: true
  # Кто разрешил выгрузку в CRM (право export). Одобрение и разрешение —
  # разные решения разных людей, поэтому и поле отдельное от reviewer.
  belongs_to :released_by, class_name: 'TelegramUser', optional: true
  has_many :transitions, -> { order(:created_at, :id) },
           class_name: 'CrmCardTransition', dependent: :destroy, inverse_of: :crm_card

  enum :kind, {
    lead: 'lead',    # заявка покупателя/арендатора → clientorder через import_client
    object: 'object' # объект продавца/арендодателя → realty, до шлюза вносится вручную
  }, prefix: true

  enum :status, {
    draft: 'draft',                   # черновик — заполняет автор
    needs_rework: 'needs_rework',     # возвращена модератором с комментарием
    pending_review: 'pending_review', # на модерации
    approved: 'approved',             # одобрена; ждёт разрешения руководителя, затем выгрузки
    exporting: 'exporting',           # выгрузка идёт прямо сейчас
    exported: 'exported',             # в CRM, crm_id известен
    export_failed: 'export_failed'    # выгрузка не удалась, ждёт повтора модератором
  }, prefix: true

  enum :export_mode, {
    api: 'api',      # через публичный API Topnlab
    manual: 'manual' # внесена руками в интерфейсе CRM, номер введён в боте
  }, prefix: true

  STATUS_LABELS = {
    'draft' => '📝 Черновик',
    'needs_rework' => '↩️ На доработке',
    'pending_review' => '⏳ На модерации',
    'approved' => '✅ Одобрена',
    'exporting' => '📤 Выгружается',
    'exported' => '🟢 В CRM',
    'export_failed' => '⚠️ Ошибка выгрузки'
  }.freeze

  # Автор правит карточку только здесь; на модерации поля правит модератор.
  AUTHOR_EDITABLE = %w[draft needs_rework].freeze
  # Выгрузка дольше этого считается прерванной: процесс упал между
  # захватом статуса и ответом CRM.
  EXPORT_STALE_AFTER = 15.minutes

  scope :not_deleted, -> { where(deleted_at: nil) }
  default_scope { not_deleted }

  # Карточки бота, который обрабатывает текущий апдейт: песочница видит
  # только свои, рабочий бот — только рабочие.
  scope :in_current_bot, -> { where(sandbox: Telegram::BotContext.test?) }

  validates :kind, :status, presence: true

  def check_passed?
    checked_at.present? && check_errors.blank?
  end

  # Заявка, застрявшая дольше EXPORT_STALE_AFTER: процесс упал между
  # захватом статуса и ответом CRM (exporting) или джоб не встал в очередь
  # после разрешения выгрузки (approved). Модератору нужна кнопка повтора,
  # иначе такую карточку не сдвинуть ничем.
  #
  # Одобренная, но ещё не разрешённая карточка застрявшей НЕ считается:
  # она ровно этого и ждёт — решения руководителя, а оно берёт столько
  # времени, сколько нужно человеку.
  def export_stale?
    return false unless kind_lead? && updated_at < EXPORT_STALE_AFTER.ago

    status_exporting? || (status_approved? && released_at.present?)
  end

  # Отпечаток того, что человек видит перед выгрузкой. Сюда входит всё, что
  # уйдёт в CRM или влияет на решение: поля карточки, ответственный и состояние
  # лида. Руководитель подтверждает не «карточку вообще», а конкретное её
  # состояние — и выгрузиться должно ровно оно.
  def release_digest
    lead = lead_event
    parts = [payload.sort.to_h.to_json, responsible&.id, lead&.current_stage,
             lead&.assigned_to_id, lead&.lead_ref.try(:crm_id)]
    Digest::SHA256.hexdigest(parts.join('|'))[0, 16]
  end

  # Кто отвечает за карточку сейчас. У заявки — текущий ответственный по
  # лиду: его назначают /assign, и он же станет ответственным в CRM, даже
  # если карточку заполнял предыдущий. У объекта — автор.
  def responsible
    (kind_lead? && lead_event&.assigned_to) || author
  end

  def last_rework_comment
    transitions.reverse.find { |t| t.to_status == 'needs_rework' }&.comment
  end
end
