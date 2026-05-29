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
    # X-Robots-Tag MUST fire before require_admin_access — when the
    # latter redirects to /users/sign_in (302) it halts the before-action
    # chain, so a header set after wouldn't apply to the redirect itself.
    # External crawlers following a stale link to /admin/anything still
    # get the noindex,nofollow signal in the 302 response.
    before_action :set_no_index_headers
    before_action :require_admin_access
    helper_method :admin_authenticated?
  end

  private

  # robots.txt Disallow already keeps obedient crawlers off /admin, but
  # Googlebot may still index URLs it learns about via external links if
  # no in-response noindex signal is present. X-Robots-Tag works even
  # for non-HTML responses (admin JSON endpoints, csv exports) where a
  # <meta name="robots"> tag is impossible.
  def set_no_index_headers
    response.headers['X-Robots-Tag'] = 'noindex, nofollow'
  end

  def require_admin_access
    return if admin_authenticated?

    # Devise user signed in but lacks the admin role → forbidden, not login.
    # Phase 14 Iter 55 — explicit Devise-feature check (раньше respond_to?
    # без guard на defined?(Devise) — хрупко если Devise полностью выпилен).
    if devise_present? && user_signed_in?
      flash[:alert] = 'Доступ только для администраторов.'
      redirect_to dashboard_root_path and return
    end

    # Phase 14 Iter 55 — fallback path: если Devise off (нет new_user_session_path),
    # redirect на /admin/login (наш token-cookie вход через AdminTokenAuth).
    sign_in_path = devise_present? && respond_to?(:new_user_session_path) ? new_user_session_path : '/admin/login'
    redirect_to sign_in_path, alert: 'Нужен вход с правами администратора.'
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

  # Phase 14 Iter 55 — single source of truth для Devise feature-flag.
  # Используется в require_admin_access + devise_admin? чтобы избегать
  # nil-deref если Devise частично выпилен. CLAUDE.md фиксирует «Devise
  # отключен» — concern должен gracefully работать с обеих сторон.
  def devise_present?
    defined?(Devise) && respond_to?(:user_signed_in?)
  end

  def devise_admin?
    return false unless devise_present?

    current_user.respond_to?(:admin?) && current_user&.admin?
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
