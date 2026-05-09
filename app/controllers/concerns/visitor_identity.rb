# frozen_string_literal: true

# Ensures every visitor (logged-in or anonymous) has a stable signed cookie
# identifying their session for the chat widget. Same token is read by
# ApplicationCable::Connection so the WebSocket subscribes to the right
# conversation stream.
module VisitorIdentity
  extend ActiveSupport::Concern

  COOKIE_NAME = :visitor_token
  COOKIE_TTL  = 90.days

  included do
    before_action :ensure_visitor_token
  end

  def ensure_visitor_token
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
