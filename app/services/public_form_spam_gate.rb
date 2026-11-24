# frozen_string_literal: true

# Общий антиспам-гейт публичных форм (issue #261, по образцу ContactFormSpamGuard
# из #239/#255 — движок переиспользует его хелперы, а не дублирует).
#
# Отличие от гейта /contacts: здесь ДРОПАЮТСЯ все сигналы — honeypot, IP из
# блэклиста (SpamBlockedEntry.ip_blocked?, точное совпадение + CIDR), rate
# limit и идемпотентность. Дроп всегда молчаливый: вызывающий контроллер
# отвечает success-ом, ничего не сохраняя и не пингуя; здесь остаётся только
# лог reason=… (образец #255).
#
# Идемпотентность (кейс бота RobertStymn из прода): двойной сабмит с тем же
# visitor_token в окне IDEMPOTENCY_WINDOW — это ОДИН сабмит. Ключ кладётся
# атомарным unless_exist — параллельные дубли из одной вкладки тоже дают
# одну запись и один пинг. Маркер посещения (бот вообще не открывал форму)
# редиректом не лечится: отсутствие/подделка signed timestamp рендера — дроп
# с тем же молчаливым success-ом, чтобы бот не разведал, что его остановило.
#
# Тайминговые сигналы (нет timestamp, слишком быстро) здесь тоже дропаются:
# в /contacts suspicious-заявку смотрит человек, а в /reviews каждый
# подозрительный отзыв — это пинг модерации, т.е. та самая спам-нагрузка.
class PublicFormSpamGate
  # Форма с видимыми полями (имя, email и т.п.) заполняется быстрее
  # 3 секунд только скриптом; порог общий для всех публичных форм.
  MIN_FILL_SECONDS = 3
  # Окно схлопывания двойного сабмита: с запасом покрывает ретраи клиента
  # и человеческое «отправить ещё раз, вдруг не прошло».
  IDEMPOTENCY_WINDOW = 15.minutes
  # Лимит по умолчанию: не больше 3 сабмитов формы в час с одного IP.
  DEFAULT_RATE_LIMIT_PER_HOUR = 3
  # Сколько срабатываний одного reason в час вызывают alert в логе.
  ALERT_THRESHOLD = 10

  DROP_REASONS = %w[honeypot spam_ip no_render_timestamp too_fast rate_limit duplicate].freeze

  # Имя honeypot-поля общее с /contacts: нейтральное, не совпадает с
  # известными полями автозаполнителей (website, email, phone и т.п.).
  HONEYPOT_PARAM = ContactFormSpamGuard::HONEYPOT_PARAM

  Result = Struct.new(:spam, :suspicious, :reason, keyword_init: true)

  class << self
    # Рендер формы: подписанный timestamp (verifier общий с /contacts).
    def rendered_at_token(now = Time.current)
      ContactFormSpamGuard.rendered_at_token(now)
    end

    def verify_rendered_at_token(token)
      ContactFormSpamGuard.verify_rendered_at_token(token)
    end

    # Ключ идемпотентности: атомарная запись маркера «сабмит уже был».
    # unless_exist → конкурентные двойные клики дают один true.
    def duplicate_submit?(form, visitor_token)
      return false if visitor_token.blank?

      !Rails.cache.write(
        idempotency_key(form, visitor_token), true,
        expires_in: IDEMPOTENCY_WINDOW, unless_exist: true
      )
    end

    def rate_limit_key(form, ip)
      "public_form:#{form}:rate:#{ip}"
    end

    def counter_key(form, reason)
      "public_form_spam:#{form}:#{reason}:#{Time.current.beginning_of_hour.to_i}"
    end

    def alert_key(form, reason)
      "public_form_spam_alert:#{form}:#{reason}:#{Time.current.beginning_of_hour.to_i}"
    end

    def idempotency_key(form, visitor_token)
      "public_form:#{form}:#{visitor_token}"
    end

    # Лог дропа: счётчик по reason + alert при превышении порога
    # (механика как ContactFormSpamGuard.record, но свои ключи и причины).
    def record(form:, reason:, ip:, ua:)
      return unless DROP_REASONS.include?(reason)

      count = Rails.cache.increment(counter_key(form, reason), 1, expires_in: 1.hour) || 0
      safe_ua = ContactFormSpamGuard.sanitize_user_agent(ua)
      Rails.logger.info(
        "[public_form:#{form}] spam dropped reason=#{reason} ip=#{ip} ua=#{safe_ua} count=#{count}"
      )
      return unless count >= ALERT_THRESHOLD && mark_alert_fired(form, reason)

      Rails.logger.warn(
        "[public_form:#{form}] ALERT reason=#{reason} threshold=#{ALERT_THRESHOLD} count=#{count}"
      )
    end

    private

    def mark_alert_fired(form, reason)
      Rails.cache.write(alert_key(form, reason), true, expires_in: 1.hour, unless_exist: true)
    end
  end

  attr_reader :reason

  # form — слаг формы для ключей rate limit/идемпотентности (например 'review');
  # rate_limit — максимум сабмитов этого form в час с одного IP.
  def initialize(form:, honeypot:, rendered_at:, ip:, visitor_token:,
                 rate_limit: DEFAULT_RATE_LIMIT_PER_HOUR, now: Time.current)
    @form          = form
    @honeypot      = honeypot.to_s.strip
    @rendered_at   = rendered_at
    @ip            = ip.to_s.strip
    @visitor_token = visitor_token.to_s.strip
    @rate_limit    = rate_limit.to_i
    @now           = now.to_f
    @reason        = nil
  end

  def call
    return spam('honeypot') if @honeypot.present?
    return spam('spam_ip') if @ip.present? && SpamBlockedEntry.ip_blocked?(@ip)

    rendered = verify_rendered_at
    return spam('no_render_timestamp') if rendered.nil?
    return spam('too_fast') if rendered > @now - MIN_FILL_SECONDS
    return spam('rate_limit') if rate_limited?
    return spam('duplicate') if self.class.duplicate_submit?(@form, @visitor_token)

    Result.new(spam: false, suspicious: false, reason: nil)
  end

  # Все причины гейта — дропы: молчаливый success без записи и пингов.
  def spam?
    reason.present?
  end

  def suspicious?
    false
  end

  # Вызывающий контроллер логирует дроп после call: спам-вердикт мог
  # поставиться и до Record, поэтому лог — отдельным шагом.
  def record(ua:)
    self.class.record(form: @form, reason: reason, ip: @ip, ua: ua)
  end

  # Откат идемпотентности для сабмита, прошедшего гейт, но не сохранившегося
  # (ошибки валидации и т.п.): маркер резервируется ДО save ради атомарного
  # схлопывания гонки двойного клика, и платой за окно владеет только
  # сохранившийся сабмит. Вызов без visitor_token — no-op.
  def release_idempotency_marker!
    return if @visitor_token.blank?

    Rails.cache.delete(self.class.idempotency_key(@form, @visitor_token))
  end

  def register_rate_limit_hit!
    Rails.cache.increment(self.class.rate_limit_key(@form, @ip), 1, expires_in: 1.hour)
  end

  private

  def verify_rendered_at
    value = self.class.verify_rendered_at_token(@rendered_at)
    value.is_a?(Numeric) ? value.to_f : nil
  end

  def rate_limited?
    return false if @rate_limit <= 0

    Rails.cache.read(self.class.rate_limit_key(@form, @ip)).to_i >= @rate_limit
  end

  def spam(reason)
    @reason = reason
    Result.new(spam: true, suspicious: false, reason: reason)
  end
end
