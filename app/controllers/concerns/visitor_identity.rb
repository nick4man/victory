# frozen_string_literal: true

# Ensures every visitor (logged-in or anonymous) has a stable signed cookie
# identifying their session for the chat widget. Same token is read by
# ApplicationCable::Connection so the WebSocket subscribes to the right
# conversation stream.
module VisitorIdentity
  extend ActiveSupport::Concern

  COOKIE_NAME = :visitor_token
  PROBE_COOKIE_NAME = :visitor_probe
  COOKIE_TTL  = 90.days

  # Префикс имени тестового прогона чат-виджета. Маркер — метка для человека,
  # в куку и Conversation она НЕ попадает (issue #229): раньше сам токен был
  # «probe-<имя>» — предсказуемым и общим для всех, кому прислали одну ссылку
  # (общий Conversation, молчаливая утечка посетителя в тестовый контур).
  # Длина суффикса ограничена 1..32 символами: без bound длинный валидный
  # суффикс упирается в лимит cookie (~4КБ) → CookieOverflow на каждый запрос.
  PROBE_TOKEN_PATTERN = /\Aprobe-[a-z0-9][a-z0-9-]{0,31}\z/.freeze
  PROBE_KEY_PARAM = :probe_key

  included do
    before_action :ensure_visitor_token
  end

  def ensure_visitor_token
    # Выход из тест-режима (issue #214): ?visitor_token=off сбрасывает обе
    # cookie, дальше по течению выпускается обычный токен — следующие лиды боевые.
    if params[:visitor_token] == 'off'
      cookies.delete(COOKIE_NAME, path: '/')
      cookies.delete(PROBE_COOKIE_NAME, path: '/')
      request.cookie_jar.delete(COOKIE_NAME)
      request.cookie_jar.delete(PROBE_COOKIE_NAME)
    end

    # Probe-режим (issue #214) — только с секретом (issue #229, блокер ревью
    # PR #228): предсказуемый URL без секрета ничего не меняет. Секрет:
    # CHAT_PROBE_SECRET если задан, иначе ADMIN_TOKEN — тот же секрет, что
    # уже выдаётся операторам для админки, отдельный ENV не требуется; пустой
    # ENV = режим отключён полностью (как вебхуки при пустом секрете).
    if probe_activation_requested? && probe_secret_valid?
      # Токен прогона — случайный и перевыпускается на каждую активацию: два
      # прогона с одним именем независимы (разные Conversation). Маркер прогона
      # живёт в подписанном флаге-куке, контроллеры чат-виджета переносят его
      # в metadata разговора (см. Conversation#test_probe?).
      set_visitor_cookies(SecureRandom.hex(16), probe: true)
      return
    end

    return if cookies.signed[COOKIE_NAME].present?

    set_visitor_cookies(SecureRandom.hex(16), probe: false)
  end

  def current_visitor_token
    cookies.signed[COOKIE_NAME]
  end

  # Маркер probe-прогона текущего визита: подписанный флаг в cookie, который
  # ставится только при активации с верным секретом. Чат-виджет переносит его
  # в metadata созданного Conversation.
  def current_visitor_probe?
    cookies.signed[PROBE_COOKIE_NAME] == true
  end

  private

  def probe_activation_requested?
    PROBE_TOKEN_PATTERN.match?(params[:visitor_token].to_s.strip.downcase)
  end

  def probe_secret_valid?
    configured = probe_secret
    if configured.blank?
      Rails.logger.warn('[VisitorIdentity] probe-режим отключён: CHAT_PROBE_SECRET/ADMIN_TOKEN не заданы')
      return false
    end

    submitted = params[PROBE_KEY_PARAM].to_s
    return false if submitted.blank?

    # Digest-сравнение по образцу AdminTokenAuth: сырой секрет не светится
    # в памяти/логах при промахе, сравнение — constant-time.
    ActiveSupport::SecurityUtils.secure_compare(
      Digest::SHA256.hexdigest(submitted),
      Digest::SHA256.hexdigest(configured)
    )
  end

  def probe_secret
    ENV['CHAT_PROBE_SECRET'].presence || ENV['ADMIN_TOKEN'].presence
  end

  def set_visitor_cookies(token, probe:)
    cookies.signed[COOKIE_NAME] = { value: token, expires: COOKIE_TTL.from_now, httponly: true, same_site: :lax }
    # Make available to current request immediately
    request.cookie_jar.signed[COOKIE_NAME] = token
    return unless probe

    cookies.signed[PROBE_COOKIE_NAME] = { value: true, expires: COOKIE_TTL.from_now, httponly: true, same_site: :lax }
    request.cookie_jar.signed[PROBE_COOKIE_NAME] = true
  end
end
