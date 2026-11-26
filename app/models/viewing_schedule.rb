# frozen_string_literal: true

# Viewing Schedule Model
# Manages property viewing appointments
#
# В схеме viewing_schedules НЕТ колонок preferred_date/preferred_time:
# форма «Запись на показ» отдаёт дату и время слота отдельными полями,
# а модель собирает из них scheduled_at/ends_at (before_validation
# :assemble_scheduled_at). Для сохранённых записей читатели
# preferred_date/preferred_time деривируются из scheduled_at — поэтому
# mailer'ы, inquiry и трекинг работают с теми же именами.
class ViewingSchedule < ApplicationRecord
  # Associations
  belongs_to :property
  belongs_to :user, optional: true
  belongs_to :agent, class_name: 'User', optional: true

  # Enums
  enum :status, {
    pending: 'pending',
    confirmed: 'confirmed',
    completed: 'completed',
    cancelled: 'cancelled',
    no_show: 'no_show'
  }

  # Виртуальные поля формы записи (см. комментарий класса): дата и время
  # слота по отдельности, как их присылает модалка.
  attribute :preferred_date, :date
  attribute :preferred_time, :string

  # Поле «Комментарий» формы — колонка notes (текст пожеланий клиента,
  # показывается в письме-подтверждении). Без алиаса ViewingSchedule.new
  # падал с UnknownAttributeError на любом сабмите модалки.
  alias_attribute :message, :notes

  # Validations
  validates :name, presence: true
  validates :phone, presence: true, format: { with: /\A\+?[0-9\s\-\(\)]+\z/ }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :preferred_date, presence: true
  validates :preferred_time, presence: true,
                             format: { with: /\A([01]?\d|2[0-3]):[0-5]\d\z/, allow_blank: true }
  validates :scheduled_at, presence: true
  validates :status, presence: true

  # Проверки слота — только при создании/переносе (и активации): иначе
  # complete!/cancel!/mark_no_show! на прошедшем показе разбивались бы
  # о date_not_in_past, а перенос слота — о time_slot_available (блокеры
  # ревью #272).
  validate :date_not_in_past, if: :slot_changed?
  validate :time_slot_available, if: :slot_or_activation_changed?

  # Callbacks
  before_validation :normalize_phone
  before_validation :assemble_scheduled_at
  after_create :send_notifications
  after_update :handle_status_change, if: :saved_change_to_status?

  # Scopes — на реальной колонке scheduled_at (раньше ходили в несуществующую
  # preferred_date и падали при любом вызове). Гранулярность прежняя —
  # календарный день: upcoming включает сегодняшние показы целиком.
  scope :recent, -> { order(created_at: :desc) }
  scope :upcoming, -> { where('scheduled_at >= ?', Time.current.beginning_of_day).where(status: %w[pending confirmed]) }
  scope :past, -> { where('scheduled_at < ?', Time.current.beginning_of_day) }
  scope :today, -> { where(scheduled_at: Time.current.all_day) }
  scope :for_property, ->(property_id) { where(property_id: property_id) }
  scope :for_user, ->(user_id) { where(user_id: user_id) }

  # Instance Methods

  # Дата/время слота для формы, mailer'ов и inquiry: у несохранённой записи —
  # то, что ввёл пользователь, у сохранённой — производные от scheduled_at.
  def preferred_date
    super || scheduled_at&.to_date
  end

  def preferred_time
    super || scheduled_at&.strftime('%H:%M')
  end

  def confirm!
    update(status: 'confirmed', confirmed_at: Time.current)
  end

  def cancel!(reason = nil)
    update(
      status: 'cancelled',
      cancelled_at: Time.current,
      cancellation_reason: reason
    )
  end

  def complete!
    update(status: 'completed', completed_at: Time.current)
  end

  def mark_no_show!
    update(status: 'no_show')
  end

  def datetime
    scheduled_at
  end

  def datetime_formatted
    return '' unless datetime

    I18n.l(datetime, format: :long)
  end

  # Продолжительность показа в минутах (колонка duration, дефолт схемы — 60).
  def duration_minutes
    duration || 60
  end

  def upcoming?
    preferred_date.present? && preferred_date >= Date.current && %w[pending confirmed].include?(status)
  end

  def can_cancel?
    %w[pending confirmed].include?(status) && preferred_date.present? && preferred_date >= Date.current
  end

  def can_confirm?
    status == 'pending' && preferred_date.present? && preferred_date >= Date.current
  end

  private

  def normalize_phone
    return unless phone.present?

    self.phone = phone.gsub(/[^\d+]/, '')
  end

  # Собирает scheduled_at/ends_at из виртуальных preferred_date/preferred_time.
  # Для сохранённой записи оба поля деривируются из scheduled_at, поэтому
  # повторная валидация идемпотентна (пересборка даёт то же значение).
  # При переносе слота ends_at пересчитывается: «автоматический» конец
  # (равен старому scheduled_at + duration) — по duration, вручную
  # выставленный — с сохранением своей длительности. Раньше ||= оставлял
  # интервал вида 12:00–11:00 (блокер 2 ревью #272).
  def assemble_scheduled_at
    return if preferred_date.blank? || preferred_time.blank?
    # Формат валидируется отдельно; мусор не собираем — иначе Time#change
    # с hour > 23 молча уехал бы на следующие сутки.
    return unless preferred_time.match?(/\A([01]?\d|2[0-3]):[0-5]\d\z/)

    hour, minute = preferred_time.split(':').map(&:to_i)
    new_start = preferred_date.in_time_zone.change(hour: hour, min: minute)

    if ends_at.nil?
      self.ends_at = new_start + duration_minutes.minutes
    elsif scheduled_at.present? && ends_at == scheduled_at + duration_minutes.minutes
      # «Автоматический» конец — переносим вместе со слотом.
      self.ends_at = new_start + duration_minutes.minutes
    elsif scheduled_at.present?
      # Ручной конец — переносим с сохранением своей длительности.
      self.ends_at = new_start + (ends_at - scheduled_at)
    end
    # Новая запись с явно заданным ends_at — оставляем как есть.

    self.scheduled_at = new_start
  end

  # Слот создаётся или переносится (новая запись либо scheduled_at изменился
  # в этой валидации — assemble_scheduled_at выше уже пересобрал его).
  def slot_changed?
    new_record? || will_save_change_to_scheduled_at?
  end

  # Переход в активный статус (подтверждение/восстановление) тоже обязан
  # пройти проверку занятости слота — слот при этом мог не меняться.
  def slot_or_activation_changed?
    slot_changed? || (will_save_change_to_status? && %w[pending confirmed].include?(status))
  end

  def date_not_in_past
    return unless preferred_date.present?

    if preferred_date < Date.current
      errors.add(:preferred_date, 'не может быть в прошлом')
    end
  end

  # Слот занят, если на этом объекте уже есть pending/confirmed-показ с
  # пересекающимся диапазоном [scheduled_at, ends_at).
  def time_slot_available
    return if scheduled_at.blank? || property_id.blank?

    slot_end = ends_at || scheduled_at + duration_minutes.minutes

    conflicting = ViewingSchedule
                  .where(property_id: property_id, status: %w[pending confirmed])
                  .where.not(id: id)
                  .where('scheduled_at < ?', slot_end)
                  .where('COALESCE(ends_at, scheduled_at + make_interval(mins => COALESCE(duration, 60))) > ?',
                         scheduled_at)

    if conflicting.exists?
      errors.add(:preferred_time, 'уже занято. Пожалуйста, выберите другое время')
    end
  end

  def send_notifications
    ViewingMailer.viewing_requested(self).deliver_later
    ViewingMailer.viewing_confirmation(self).deliver_later if email.present?
  end

  def handle_status_change
    case status
    when 'confirmed'
      ViewingMailer.viewing_confirmed(self).deliver_later if email.present?
    when 'cancelled'
      ViewingMailer.viewing_cancelled(self).deliver_later if email.present?
    when 'completed'
      ViewingMailer.viewing_completed(self).deliver_later if email.present?
    end
  end
end
