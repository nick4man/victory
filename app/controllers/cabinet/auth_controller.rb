# frozen_string_literal: true

# Magic-link авторизация для /cabinet (non-Devise).
#
# Flow:
#   1. GET  /cabinet/login            → форма (email или phone)
#   2. POST /cabinet/login            → MagicLinkToken.generate! + CabinetMailer.magic_link
#                                        Всегда возвращает success flash (security:
#                                        не leak whether identifier exists)
#   3. GET  /cabinet/verify/:token    → consume token + session[:cabinet_user_id]
#   4. DELETE /cabinet/logout         → clear session
#
# Rate limit: 5/час per IP. Mirror'ит PropertyValuationsController#rate_limited?
# Redis DB 1, namespace cabinet:link_request:*.
class Cabinet::AuthController < ApplicationController
  RATE_LIMIT = { count: 5, window: 1.hour }.freeze

  before_action :enforce_rate_limit, only: :create

  def new
    redirect_to cabinet_path and return if session[:cabinet_user_id].present?
    # render cabinet/auth/new.html.erb
  end

  def create
    identifier = params[:identifier].to_s.strip
    if identifier.blank?
      flash.now[:alert] = 'Введите email или телефон.'
      render :new, status: :unprocessable_entity and return
    end

    type = identifier.match?(/@/) ? 'email' : 'phone'
    user = lookup_user(identifier, type)

    # Security: всегда показываем success — не leak'аем существует ли
    # identifier в базе. Token создаётся ВСЕГДА (audit trail), но mail
    # отправляется только если user найден.
    token = MagicLinkToken.generate!(identifier: identifier, identifier_type: type, request: request)
    if user
      if type == 'email'
        CabinetMailer.magic_link(user, token).deliver_later
      else
        # Phase 2: SMS gateway. Пока no-op.
        Rails.logger.info("[Cabinet::Auth] SMS magic-link not yet implemented for user=#{user.id}")
      end
    end

    flash[:notice] = if type == 'email'
                       'Если этот email у нас есть — ссылка отправлена. Проверьте почту (в т.ч. спам).'
                     else
                       'SMS-вход пока в разработке. Используйте email-вход.'
                     end
    redirect_to cabinet_login_path
  end

  def verify
    token = MagicLinkToken.valid.find_by(token: params[:token])
    if token.nil?
      flash[:alert] = 'Ссылка недействительна или истекла. Запросите новую.'
      redirect_to cabinet_login_path and return
    end

    user = lookup_user(token.identifier, token.identifier_type)
    if user.nil?
      flash[:alert] = 'Пользователь не найден. Возможно, аккаунт был удалён.'
      redirect_to cabinet_login_path and return
    end

    unless token.consume!
      flash[:alert] = 'Ссылка уже использована. Запросите новую.'
      redirect_to cabinet_login_path and return
    end

    reset_session
    session[:cabinet_user_id] = user.id
    flash[:notice] = "С возвращением, #{user.first_name.presence || user.email}!"
    redirect_to cabinet_path
  end

  def destroy
    session.delete(:cabinet_user_id)
    redirect_to cabinet_login_path, notice: 'Вы вышли из кабинета.'
  end

  private

  # Email — exact LOWER match. Phone — last-10-digit suffix match
  # (РФ phones хранятся в разных форматах: 79..., 89..., +79...).
  def lookup_user(identifier, type)
    scope = User.where(active: true, deleted_at: nil)
    case type.to_s
    when 'email'
      normalized = identifier.to_s.strip.downcase
      scope.find_by('LOWER(email) = ?', normalized)
    when 'phone'
      digits = identifier.to_s.gsub(/\D/, '').last(10)
      return nil if digits.length < 10

      scope.where('phone LIKE ?', "%#{digits}").first
    end
  end

  def enforce_rate_limit
    return false unless defined?(Redis)

    key = "cabinet:link_request:#{request.remote_ip}"
    redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://redis:6379/1'))
    count = redis.incr(key)
    redis.expire(key, RATE_LIMIT[:window].to_i) if count == 1
    return if count <= RATE_LIMIT[:count]

    flash[:alert] = 'Слишком много запросов. Попробуйте через час.'
    redirect_to cabinet_login_path
  rescue Redis::BaseError => e
    Rails.logger.warn("[Cabinet::Auth] rate-limit Redis error: #{e.message}")
    nil  # soft-fail — не блокируем
  end
end
