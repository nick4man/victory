# frozen_string_literal: true

# Shared token-based admin gate used by every controller under /admin
# (Articles, Reviews, Dashboard). Devise's full user roles are paused; this
# concern lets a small set of operators reach moderation pages by entering
# `ENV['ADMIN_TOKEN']` once on /admin/login. After that the digest is kept
# in the encrypted session cookie until they click ВЫХОД.
#
# Two acceptance paths:
#   1. `?token=...` URL param — used by chat-host links and the initial
#      session-cookie bootstrap. Still works for bookmarks.
#   2. `session[:admin_token_digest]` — set by Admin::SessionsController#create
#      after a successful POST; survives navigation without leaking token in
#      URLs.
#
# Both compare constant-time against `Digest::SHA256.hexdigest(ENV[...])`,
# never against the raw token, so the cookie value is safe at rest.
module AdminTokenAuth
  extend ActiveSupport::Concern

  included do
    before_action :require_admin_access
    helper_method :admin_authenticated?
  end

  private

  def require_admin_access
    return if admin_authenticated?

    # Devise user signed in but lacks the admin role → forbidden, not login.
    if respond_to?(:user_signed_in?) && user_signed_in?
      flash[:alert] = 'Доступ только для администраторов.'
      redirect_to dashboard_root_path and return
    end

    redirect_to new_user_session_path, alert: 'Нужен вход с правами администратора.'
  end

  # Two acceptance paths kept side-by-side so server-to-server callers
  # (chat-host webhooks, automation that doesn't carry a session cookie)
  # can still reach the admin pages via `?token=…`, while interactive
  # operators just log in via Devise as a user with role=admin.
  def admin_authenticated?
    return true if devise_admin?
    return true if token_admin?

    false
  end

  def devise_admin?
    respond_to?(:current_user) && current_user.respond_to?(:admin?) && current_user.admin?
  end

  def token_admin?
    expected = ENV['ADMIN_TOKEN'].to_s
    return false if expected.blank?

    expected_digest = ::Digest::SHA256.hexdigest(expected)

    if params[:token].present?
      url_digest = ::Digest::SHA256.hexdigest(params[:token].to_s)
      if ::ActiveSupport::SecurityUtils.secure_compare(url_digest, expected_digest)
        session[:admin_token_digest] = expected_digest
        return true
      end
    end

    cookie_digest = session[:admin_token_digest].to_s
    return false if cookie_digest.blank?

    ::ActiveSupport::SecurityUtils.secure_compare(cookie_digest, expected_digest)
  end
end
