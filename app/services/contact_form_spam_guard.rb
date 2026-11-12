# frozen_string_literal: true

# Антиспам-гейт для формы обратной связи /contacts (source: 'contact_form').
# Issue #223: 381 SEO-спам-заявки за 4 дня, 375+ карточек в ДИСПЕТЧЕРСКОЙ.
#
# Выбран минимально достаточный вариант из issue — honeypot + тайминг
# (капча оставлена на случай, если поток продолжится). Оба сигнала
# прозрачны для человека:
#   1. honeypot — CSS-скрытое поле `website`; люди его не видят и не
#      заполняют, боты шлют всё подряд.
#   2. тайминг — GET /contacts кладёт timestamp в сессию; submit быстрее
#      MIN_FILL_SECONDS после рендера (или вообще без рендера — прямой
#      POST без визита на страницу) = бот.
#
# Дроп «молчаливый»: контроллер отвечает боту как при успехе и не создаёт
# Inquiry — сигнала «тебя раскрыли» нет, бот не адаптируется. Причина
# пишется в лог для наблюдаемости.
class ContactFormSpamGuard
  # Быстрее 3 секунд после рендера формы физически не заполняют 4 поля.
  MIN_FILL_SECONDS = 3
  SESSION_KEY = :contact_form_rendered_at
  # Plausible-имя для ботов; реальные параметры формы его не используют.
  HONEYPOT_PARAM = :website

  REASONS = %w[honeypot no_render_timestamp too_fast].freeze

  Result = Struct.new(:spam, :reason, keyword_init: true)

  def self.check(honeypot:, rendered_at:, now: Time.current)
    new(honeypot: honeypot, rendered_at: rendered_at, now: now).check
  end

  def initialize(honeypot:, rendered_at:, now:)
    @honeypot = honeypot.to_s.strip
    @rendered_at = rendered_at
    @now = now.to_f
  end

  def check
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
