# frozen_string_literal: true

# Антиспам-гейт для формы обратной связи /contacts (source: 'contact_form'), issue #223.
#
# Молчаливый дроп: контроллер отвечает боту как при успехе и не создаёт Inquiry —
# сигнала «тебя раскрыли» нет, бот не адаптируется. Причина пишется в лог.
class ContactFormSpamGuard
  # Быстрее 3 секунд после рендера формы физически не заполняют 4 поля.
  MIN_FILL_SECONDS = 3
  SESSION_KEY = :contact_form_rendered_at
  # Plausible-имя для ботов; реальные параметры формы его не используют.
  HONEYPOT_PARAM = :website

  REASONS = %w[honeypot no_render_timestamp too_fast].freeze

  Result = Struct.new(:spam, :reason, keyword_init: true)

  def initialize(honeypot:, rendered_at:, now: Time.current)
    @honeypot = honeypot.to_s.strip
    @rendered_at = rendered_at
    @now = now.to_f
  end

  def call
    return spam('honeypot') if @honeypot.present?
    return spam('no_render_timestamp') if @rendered_at.blank?
    return spam('too_fast') if @now - @rendered_at.to_f < MIN_FILL_SECONDS

    Result.new(spam: false, reason: nil)
  end

  private

  def spam(reason)
    Result.new(spam: true, reason: reason)
  end
end
