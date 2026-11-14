# frozen_string_literal: true

# Антиспам-гейт для формы обратной связи /contacts (source: 'contact_form'), issue #239.
#
# - Молчаливый дроп оставлен только для honeypot.
# - Тайминговые сигналы (нет timestamp, слишком быстро) не дропают заявку:
#   Inquiry создаётся со статусом new и меткой suspicious в metadata.
# - Timestamp рендера передаётся подписанным скрытым полем формы
#   (ActiveSupport::MessageVerifier) вместо сессии — убирает гонку вкладок
#   и зависимость от cookie.
# - Ведётся счётчик срабатываний по reason; при превышении порога логируется
#   alert. User-agent в логе санитизируется от \r\n.
class ContactFormSpamGuard
  # Быстрее 3 секунд после рендера формы физически не заполняют 4 поля.
  MIN_FILL_SECONDS = 3
  # Нейтральное имя для honeypot: не должно совпадать с известными полями
  # автозаполнителей (website, email, phone и т.п.).
  HONEYPOT_PARAM = :contact_code
  # Сколько срабатываний одного reason в час вызывают alert в логе.
  ALERT_THRESHOLD = 10

  REASONS = %w[honeypot no_render_timestamp too_fast].freeze

  Result = Struct.new(:spam, :suspicious, :reason, keyword_init: true)

  class << self
    def rendered_at_token(now = Time.current)
      verifier.generate(now.to_f)
    end

    def verify_rendered_at_token(token)
      return nil unless token.is_a?(String) && token.present?

      verifier.verify(token)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    # Подписанный stateless CSRF-токен для формы /contacts.
    # Работает без session cookie — убирает ещё один источник потери заявок
    # при блокировке/очистке cookie (GDPR-расширения, Safari ITP, bfcache).
    #
    # binding — массив [visitor_token, client_fingerprint]. Токен принимается,
    # если совпадает хотя бы одна из связок: это позволяет не терять заявку
    # при удалении session cookie, но не даёт replay токен с другого браузера/IP.
    def form_csrf_token(binding)
      verifier(:contact_form_csrf).generate([SecureRandom.hex(16), Time.current.to_f, *binding])
    end

    def verify_form_csrf_token(token, binding)
      return false unless token.is_a?(String) && token.present?

      _nonce, _issued_at, token_visitor, token_fingerprint = verifier(:contact_form_csrf).verify(token)
      token_visitor.to_s == binding[0].to_s || token_fingerprint.to_s == binding[1].to_s
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      false
    end

    def record(reason:, ip:, ua:)
      return unless REASONS.include?(reason)

      count = increment_counter(reason)
      safe_ua = sanitize_user_agent(ua)
      kind = reason == 'honeypot' ? 'dropped' : 'suspicious'
      Rails.logger.info(
        "[contact_form] spam #{kind} reason=#{reason} ip=#{ip} ua=#{safe_ua} count=#{count}"
      )
      log_alert(reason, count) if count >= ALERT_THRESHOLD
    end

    def counter_key(reason)
      "contact_form_spam:#{reason}:#{Time.current.beginning_of_hour.to_i}"
    end

    def alert_key(reason)
      "contact_form_spam_alert:#{reason}:#{Time.current.beginning_of_hour.to_i}"
    end

    def sanitize_user_agent(ua)
      ua.to_s.gsub(/[\r\n]+/, ' ').truncate(120)
    end

    private

    def verifier(purpose = 'contact_form_rendered_at')
      Rails.application.message_verifier(purpose)
    end

    def increment_counter(reason)
      # Redis: INCRBY на несуществующем ключе создаёт его;
      # expires_in задаёт TTL атомарно (не через предварительный write,
      # который сериализует значение и ломает INCRBY).
      Rails.cache.increment(counter_key(reason), 1, expires_in: 1.hour) || 0
    end

    def log_alert(reason, count)
      # Атомарно ставим маркер: если ключ уже есть, другой
      # процесс уже залогировал alert в этом окне.
      return unless mark_alert_fired(reason)

      Rails.logger.warn(
        "[contact_form] ALERT reason=#{reason} threshold=#{ALERT_THRESHOLD} count=#{count}"
      )
    end

    def mark_alert_fired(reason)
      Rails.cache.write(alert_key(reason), true, expires_in: 1.hour, unless_exist: true)
    end
  end

  def initialize(honeypot:, rendered_at:, now: Time.current)
    @honeypot = honeypot.to_s.strip
    @rendered_at = rendered_at
    @now = now.to_f
  end

  def call
    return spam('honeypot') if @honeypot.present?
    return suspicious('no_render_timestamp') if @rendered_at.blank?
    return suspicious('too_fast') if @now - @rendered_at.to_f < MIN_FILL_SECONDS

    Result.new(spam: false, suspicious: false, reason: nil)
  end

  private

  def spam(reason)
    Result.new(spam: true, suspicious: false, reason: reason)
  end

  def suspicious(reason)
    Result.new(spam: false, suspicious: true, reason: reason)
  end
end
