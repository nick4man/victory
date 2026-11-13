# frozen_string_literal: true

# Ensures every visitor (logged-in or anonymous) has a stable signed cookie
# identifying their session for the chat widget. Same token is read by
# ApplicationCable::Connection so the WebSocket subscribes to the right
# conversation stream.
module VisitorIdentity
  extend ActiveSupport::Concern

  COOKIE_NAME = :visitor_token
  COOKIE_TTL  = 90.days

  # Префикс токена тестового прогона чат-виджета. Открытие сайта с
  # ?visitor_token=probe-<имя> фиксирует токен в куке — весь чат этого
  # посетителя идёт в тестовый канал, а не в ДИСПЕТЧЕРСКУЮ (issue #214).
  # Длина суффикса ограничена 1..32 символами: без bound длинный валидный
  # суффикс упирается в лимит cookie (~4КБ) → CookieOverflow на каждый запрос.
  PROBE_TOKEN_PATTERN = /\Aprobe-[a-z0-9][a-z0-9-]{0,31}\z/.freeze

  included do
    before_action :ensure_visitor_token
  end

  def ensure_visitor_token
    # Выход из тест-режима (issue #214): ?visitor_token=off сбрасывает cookie,
    # дальше по течению выпускается обычный токен — следующие лиды боевые.
    if params[:visitor_token] == 'off'
      cookies.delete(COOKIE_NAME, path: '/')
      request.cookie_jar.delete(COOKIE_NAME)
    end

    # Только probe-префикс: произвольный токен из URL не принимаем — иначе
    # подделка куки тривиальна (подпись ставится на то, что прислали).
    probe = params[:visitor_token].to_s.strip.downcase
    if PROBE_TOKEN_PATTERN.match?(probe)
      cookies.signed[COOKIE_NAME] = { value: probe, expires: COOKIE_TTL.from_now, httponly: true, same_site: :lax }
      request.cookie_jar.signed[COOKIE_NAME] = probe
      return
    end

    return if cookies.signed[COOKIE_NAME].present?

    token = SecureRandom.hex(16)
    cookies.signed[COOKIE_NAME] = {
      value:    token,
      expires:  COOKIE_TTL.from_now,
      httponly: true,
      same_site: :lax
    }
    # Make available to current request immediately
    request.cookie_jar.signed[COOKIE_NAME] = token
  end

  def current_visitor_token
    cookies.signed[COOKIE_NAME]
  end
end
