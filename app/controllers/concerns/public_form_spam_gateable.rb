# frozen_string_literal: true

# Общая точка входа публичных форм в антиспам-гейт (issue #262, часть 2).
# Собирает PublicFormSpamGate из параметров запроса; молчаливый дроп и
# success-ответы остаются в контроллерах — у каждой формы своя форма успеха.
module PublicFormSpamGateable
  extend ActiveSupport::Concern

  private

  # form — слаг формы для ключей гейта (rate limit/идемпотентность/счётчики).
  # rate_limit: 0 — счётчик гейта выключен (у эндпоинта уже есть свой лимит,
  # гейт его не ужесточает). require_render_token: false — для эндпоинтов
  # без живой формы (нет подписанного timestamp рендера). visitor_token: nil —
  # без идемпотентности (повторный сабмит с одного браузера легитимен).
  def public_form_spam_gate(form, rate_limit: PublicFormSpamGate::DEFAULT_RATE_LIMIT_PER_HOUR,
                            require_render_token: true, visitor_token: current_visitor_token)
    PublicFormSpamGate.new(
      form:                 form,
      honeypot:             params[PublicFormSpamGate::HONEYPOT_PARAM],
      rendered_at:          params[:rendered_at_token],
      ip:                   request.remote_ip,
      visitor_token:        visitor_token,
      rate_limit:           rate_limit,
      require_render_token: require_render_token
    )
  end
end
