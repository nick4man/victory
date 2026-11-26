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

  # Проверки слота — не на каждом update, а по делу (блокеры ревью #272/#273):
  # - date_not_in_past — при создании/переносе слота И при переходе в активный
  #   статус: иначе confirm! вчерашнего pending или восстановление прошедшего
  #   cancelled в активный статус проходили бы без проверки даты (и это
  #   противоречит can_confirm?);
  # - time_slot_available — там же, плюс при правке ends_at/property_id:
  #   confirm!/восстановление на занятом слоте и удлинение показа до
  #   пересечения с соседним отклоняются. Переводы в неактивные статусы
  #   (complete!/cancel!/mark_no_show!) на прошедшем показе обе проверки
  #   пропускают.
  validate :date_not_in_past, if: :slot_or_activation_changed?
  validate :time_slot_available, if: :slot_overlap_check_needed?
  validate :ends_after_start, if: :slot_overlap_check_needed?

  # Callbacks
  before_validation :normalize_phone
  before_validation :assemble_scheduled_at
  after_save :clear_form_fields
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

  # Факт явного присваивания ends_at (а не разница значений): одновременный
  # перенос слота с явно переданным ПРЕЖНИМ концом даёт will_save_change_to_
  # ends_at? == false, и сборка молча заменяла бы осознанное значение
  # автоматическим (блокер 1 ревью раунда 5). Сбрасывается после save
  # (clear_form_fields) — сохранённое значение больше не «явное».
  def ends_at=(value)
    @ends_at_explicit = true
    super
  end

  def ends_at_explicitly_assigned?
    @ends_at_explicit
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

  # Собирает scheduled_at из ЯВНО переданных полей формы (preferred_date/
  # preferred_time): у сохранённой записи читатели деривируются из
  # scheduled_at, поэтому пересборка идёт только когда форма реально прислала
  # значения — прямое присваивание scheduled_at= перетираться не должно.
  #
  # ends_at следует за scheduled_at при ЛЮБОМ переносе (форма или прямое
  # присваивание): «автоматический» конец — по duration, ручной — с
  # сохранением своей длительности. Автоматичность классифицируется по
  # СОХРАНЁННОЙ паре scheduled_at/ends_at (attribute_in_database), а не по
  # текущим значениям — иначе повторная валидация уже перенесённого конца
  # считала бы его «ручным» и растягивала интервал: 10:00–11:00 → 12:00–
  # 13:00 → 12:00–15:00 (блокер 1 ревью раунда 3). Явно заданный ends_at
  # новой записи не затирается.
  def assemble_scheduled_at
    form_date = self[:preferred_date]
    form_time = self[:preferred_time]
    # Пересборка — только когда форма реально прислала значения (после save
    # виртуальные поля сброшены, см. clear_form_fields): прямое присваивание
    # scheduled_at= перетираться не должно. Недостающую половину (формат
    # «дата+время» пересылается целиком, но модель допускает частичное
    # обновление) берём из текущего scheduled_at.
    if form_date.present? || form_time.present?
      date = form_date.presence || scheduled_at&.to_date
      time = form_time.presence || scheduled_at&.strftime('%H:%M')
      # Формат времени валидируется отдельно; мусор не собираем — иначе
      # Time#change с hour > 23 молча уехал бы на следующие сутки.
      if date.present? && time.present? && time.match?(/\A([01]?\d|2[0-3]):[0-5]\d\z/)
        hour, minute = time.split(':').map(&:to_i)
        self.scheduled_at = date.in_time_zone.change(hour: hour, min: minute)
      end
    end

    return if scheduled_at.blank?

    persisted_start = scheduled_at_in_database
    persisted_end = ends_at_in_database

    if persisted_start.nil?
      # Новая запись: явно заданный ends_at не трогаем; автоматический —
      # пересчитываем при КАЖДОМ изменении начала/duration, иначе после
      # неудачной валидации и смены времени конец «застрянет» на значении
      # прошлой сборки и даст перевёрнутый интервал 12:00–11:00 (блокер 1
      # ревью раунда 4).
      self[:ends_at] = scheduled_at + duration_minutes.minutes unless ends_at_explicitly_assigned?
    elsif ends_at_explicitly_assigned?
      # ends_at присвоен явно (отдельно или вместе с переносом слота) —
      # осознанная правка границ, не перетираем; её же ловит проверка
      # пересечений (slot_overlap_check_needed?).
    elsif will_save_change_to_scheduled_at? || will_save_change_to_duration?
      # «Автоматический» конец — по СОХРАНЁННОЙ паре и сохранённой duration:
      # повторная валидация уже перенесённого конца не должна считать его
      # «ручным» и растягивать интервал (10:00–11:00 → 12:00–13:00 →
      # 12:00–15:00, блокер 1 ревью раунда 3).
      if persisted_end.nil? || persisted_end == persisted_start + (duration_in_database || 60).minutes
        self[:ends_at] = scheduled_at + duration_minutes.minutes
      elsif will_save_change_to_scheduled_at?
        # Ручной конец при переносе — с сохранением сохранённой длительности.
        self[:ends_at] = scheduled_at + (persisted_end - persisted_start)
      end
    end
    # Без смены слота/duration чужое ends_at не трогаем.
  end

  # Виртуальные поля формы — ввод пользователя для текущего сабмита, а не
  # состояние записи: после сохранения сбрасываем. Иначе «застрявшие»
  # значения перетирали бы прямое присваивание scheduled_at= (блокер 2
  # ревью #273), а читатели preferred_date/preferred_time для сохранённой
  # записи всё равно деривируются из scheduled_at.
  def clear_form_fields
    self[:preferred_date] = nil
    self[:preferred_time] = nil
    # Сохранённое ends_at больше не «явное присваивание» — см. ends_at=.
    @ends_at_explicit = false
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

  # Проверка пересечений нужна и при правке границ/объекта без смены начала:
  # update(ends_at: ...) может удлинить показ до пересечения с соседним,
  # update(property_id: ...) — перенести его на занятый слот другого
  # объекта (блокер 2 ревью раунда 3). Проверка даты при этом не запускается
  # (slot_or_activation_changed?): правка границ прошедшего показа для
  # отчётности — легитимна.
  def slot_overlap_check_needed?
    slot_or_activation_changed? || will_save_change_to_ends_at? || will_save_change_to_property_id?
  end

  def date_not_in_past
    return unless preferred_date.present?

    if preferred_date < Date.current
      errors.add(:preferred_date, 'не может быть в прошлом')
    end
  end

  # Инвертированный или нулевой интервал — невалиден независимо от занятости
  # соседних слотов (блокер 2 ревью раунда 4): проверка пересечений порядок
  # границ не гарантирует. Срабатывает там же, где и проверка пересечений;
  # на переводы статусов прошедших показов не распространяется.
  def ends_after_start
    return if scheduled_at.blank? || ends_at.blank?

    errors.add(:ends_at, 'должно быть позже начала показа') if ends_at <= scheduled_at
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
