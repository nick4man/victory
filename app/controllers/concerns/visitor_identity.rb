# frozen_string_literal: true

# Ensures every visitor (logged-in or anonymous) has a stable signed cookie
# identifying their session for the chat widget. Same token is read by
# ApplicationCable::Connection so the WebSocket subscribes to the right
# conversation stream.
module VisitorIdentity
  extend ActiveSupport::Concern

  COOKIE_NAME = :visitor_token
  COOKIE_TTL  = 90.days

  # Префикс токена тестового прогона чат-виджета. Открытие сайта со
  # СВЕРЕННЫМ probe-токеном фиксирует его в куке — весь чат этого
  # посетителя идёт в тестовый канал, а не в ДИСПЕТЧЕРСКУЮ (issue #214).
  #
  # Review round 6 (PR #228): раньше принимался любой `?visitor_token=probe-x` —
  # сервер сам подписывал произвольное значение в куку на 90 дней, поэтому
  # ссылка, пройдя по которой реальный клиент «стал тестовым», была
  # публично подделываема. Теперь суффикс токена — HMAC-SHA256 от имени
  # (secret_key_base): подделка требует секрета сервера. Токен выдаёт
  # VisitorIdentity.probe_token (консоль/rake), имя внутри — уникальное,
  # чтобы у разных прогонов не было общего Conversation.
  PROBE_TOKEN_PATTERN = /\Aprobe-([a-z0-9][a-z0-9-]{0,15})-([0-9a-f]{16})\z/.freeze

  # Токен тест-прогона для ссылки вида /?visitor_token=<токен>.
  # Имя по умолчанию уникально на вызов — общий probe-<name> у разных
  # посетителей давал бы общий Conversation/историю.
  def self.probe_token(name = nil)
    name ||= "t#{SecureRandom.hex(3)}"
    base = "probe-#{name.to_s.downcase}"
    "#{base}-#{probe_signature(base)}"
  end

  def self.valid_probe_token?(token)
    match = PROBE_TOKEN_PATTERN.match(token.to_s)
    return false unless match
    base = "probe-#{match[1]}"
    ActiveSupport::SecurityUtils.secure_compare(match[2], probe_signature(base))
  end

  def self.probe_signature(base)
    OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, base)[0, 16]
  end
  private_class_method :probe_signature

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

    # Только probe с валидной HMAC-подписью (round 6): произвольное и
    # самодельное значение из URL не принимаем — сервер подписывает в куку
    # лишь то, что мог выдать только он (VisitorIdentity.probe_token).
    probe = params[:visitor_token].to_s.strip.downcase
    if VisitorIdentity.valid_probe_token?(probe)
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
