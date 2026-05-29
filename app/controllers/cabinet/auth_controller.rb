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

  # Стандартный stdlib regex для email — отвергает пробелы, нелатиницу
  # в domain, обрывки. Это первая линия защиты перед SMTP — Mail.ru
  # 550 invalid-headers если в `to:` попадёт мусор.
  EMAIL_REGEX = URI::MailTo::EMAIL_REGEXP

  before_action :enforce_rate_limit, only: :create

  def new
    redirect_to cabinet_path and return if session[:cabinet_user_id].present?
    # render cabinet/auth/new.html.erb
  end

  # POST /cabinet/login — branches by params:
  #   - params[:password].present? → password-based login (BCrypt compare)
  #   - else → magic-link flow (existing)
  def create
    identifier = params[:identifier].to_s.strip
    password = params[:password].to_s
    if identifier.blank?
      flash.now[:alert] = 'Введите email или телефон.'
      render :new, status: :unprocessable_entity and return
    end

    # Detect type + строгая validation. Если в строке есть `@`,
    # обязан соответствовать EMAIL_REGEX — иначе reject (защита от
    # мусора в SMTP `to:` header, который Mail.ru отдаёт как 550).
    if identifier.include?('@')
      unless identifier.match?(EMAIL_REGEX)
        @identifier_prefill = identifier
        flash.now[:alert] = 'Введите корректный email (без пробелов, латиница).'
        render :new, status: :unprocessable_entity and return
      end
      type = 'email'
    else
      type = 'phone'
    end

    # Password-first branch: ONLY if password field submitted.
    return authenticate_with_password(identifier, password) if password.present?

    # Otherwise — magic-link flow.
    user = lookup_user(identifier, type)
    token = MagicLinkToken.generate!(identifier: identifier, identifier_type: type, scope: 'login', request: request)

    # Option A — auto-create User on FIRST email login if not found.
    # We still send the magic-link in either case; verify-action does the
    # actual User.create! after token consumed (email ownership proven).
    #
    # NB: для существующего user'а — deliver_later (Sidekiq может
    # GlobalID-сериализовать ActiveRecord). Для stub'а (не-AR Struct)
    # ActiveJob падает с SerializationError — поэтому deliver_now.
    if type == 'email'
      if user
        CabinetMailer.magic_link(user, token).deliver_later
      else
        CabinetMailer.magic_link(build_stub_user_for_mailer(identifier), token).deliver_now
      end
    elsif user
      Rails.logger.info("[Cabinet::Auth] SMS magic-link not yet implemented for user=#{user.id}")
    end

    flash[:notice] = if type == 'email'
                       'Ссылка для входа отправлена на email. Проверьте почту (в т.ч. спам). ' \
                       'Если у вас ещё нет аккаунта, он будет создан при первом входе.'
                     else
                       'SMS-вход пока в разработке. Используйте email-вход.'
                     end
    redirect_to cabinet_login_path
  end

  # Mailer needs an object с .email + .first_name. Если User ещё не существует
  # (Option A new-registration), отдаём lightweight Struct, чтобы шаблон не
  # падал на @user.first_name nil-check.
  def build_stub_user_for_mailer(email)
    Struct.new(:email, :first_name).new(email, nil)
  end

  # Password-based auth — использует Devise#valid_password? (handles pepper
  # + cost). Email-only (phone не используется для password auth).
  def authenticate_with_password(identifier, password)
    return reject_password('Пароль работает только с email') unless identifier.match?(/@/)

    user = lookup_user(identifier, 'email')
    return reject_password('Неверный email или пароль') if user.nil?
    return reject_password('Неверный email или пароль') if user.encrypted_password.blank?
    return reject_password('Неверный email или пароль') unless user.valid_password?(password)

    reset_session
    session[:cabinet_user_id] = user.id
    flash[:notice] = "С возвращением, #{user.first_name.presence || user.email}!"
    redirect_to cabinet_path
  end

  def verify
    # Scope to 'login' tokens — password_reset tokens consume через
    # Cabinet::PasswordsController (отдельный flow).
    token = MagicLinkToken.valid.where(scope: 'login').find_by(token: params[:token])
    if token.nil?
      flash[:alert] = 'Ссылка недействительна или истекла. Запросите новую.'
      redirect_to cabinet_login_path and return
    end

    # Option A: auto-create User on first email magic-link verify (email
    # ownership proven by token possession).
    user = lookup_user(token.identifier, token.identifier_type) || auto_register_user(token)
    if user.nil?
      flash[:alert] = 'Не удалось создать аккаунт. Свяжитесь с поддержкой.'
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

  # Option A — first-time auto-registration. Only email tokens (phone-OTP
  # registration TBD). Random unguessable password — user can set real one
  # через /cabinet/password/reset когда захочет. role=:client.
  def auto_register_user(token)
    return nil unless token.identifier_type == 'email'

    email = token.identifier.to_s.strip.downcase
    return nil if email.blank? || !email.include?('@')

    User.create!(
      email:      email,
      password:   SecureRandom.urlsafe_base64(32),
      first_name: 'Клиент',
      last_name:  '—',
      role:       :client,
      active:     true,
      crm_status: 'active'
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[Cabinet::Auth] auto_register_user failed for #{token.identifier}: #{e.message}")
    nil
  end

  def destroy
    session.delete(:cabinet_user_id)
    redirect_to cabinet_login_path, notice: 'Вы вышли из кабинета.'
  end

  private

  # Generic rejection helper для password flow. ВСЕГДА показывает
  # одинаковую ошибку «Неверный email или пароль» (security: не leak
  # whether email exists или password mismatch).
  def reject_password(msg)
    flash.now[:alert] = msg
    @identifier_prefill = params[:identifier]
    render :new, status: :unprocessable_entity
  end

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
