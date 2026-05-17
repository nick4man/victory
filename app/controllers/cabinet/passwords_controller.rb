# frozen_string_literal: true

# Password reset flow для /cabinet (re-uses MagicLinkToken scope='password_reset').
#
# Flow:
#   1. GET  /cabinet/password/reset            → форма (email)
#   2. POST /cabinet/password/reset            → MagicLinkToken.generate!(scope:'password_reset')
#                                                 + CabinetMailer.password_reset
#   3. GET  /cabinet/password/edit?token=...   → форма (new password + confirm)
#   4. PATCH /cabinet/password                 → verify + update User.encrypted_password
#                                                 + consume token + auto-login session
#
# Security:
#   - Same rate-limit как login (5/час per IP)
#   - Token: single-use, 30 min, scope-isolated от login tokens
#   - User.encrypted_password — BCrypt (10 rounds, Devise schema)
#   - Generic «Если этот email у нас есть — ссылка отправлена» response (не leak existence)
class Cabinet::PasswordsController < ApplicationController
  RATE_LIMIT = { count: 5, window: 1.hour }.freeze

  before_action :enforce_rate_limit, only: :create

  # GET /cabinet/password/reset — форма ввода email
  def new; end

  # POST /cabinet/password/reset
  def create
    identifier = params[:identifier].to_s.strip
    if identifier.blank? || !identifier.match?(URI::MailTo::EMAIL_REGEXP)
      flash.now[:alert] = 'Введите корректный email — сброс пароля работает только через email.'
      render :new, status: :unprocessable_entity and return
    end

    user = User.where(active: true, deleted_at: nil)
                .find_by('LOWER(email) = ?', identifier.downcase)

    if user
      token = MagicLinkToken.generate!(
        identifier:      identifier,
        identifier_type: 'email',
        scope:           'password_reset',
        request:         request
      )
      CabinetMailer.password_reset(user, token).deliver_later
    end

    flash[:notice] = 'Если этот email у нас есть — ссылка для смены пароля отправлена. ' \
                     'Проверьте почту (в т.ч. спам). Ссылка действительна 30 минут.'
    redirect_to cabinet_login_path
  end

  # GET /cabinet/password/edit?token=...
  def edit
    @token = find_valid_token(params[:token])
    return redirect_with_alert('Ссылка недействительна или истекла.') if @token.nil?
  end

  # PATCH /cabinet/password
  def update
    token = find_valid_token(params[:token])
    return redirect_with_alert('Ссылка недействительна или истекла.') if token.nil?

    password = params[:password].to_s
    confirm  = params[:password_confirmation].to_s

    if password.length < 8
      @token = token
      flash.now[:alert] = 'Пароль должен быть не короче 8 символов.'
      render :edit, status: :unprocessable_entity and return
    end

    if password != confirm
      @token = token
      flash.now[:alert] = 'Пароли не совпадают.'
      render :edit, status: :unprocessable_entity and return
    end

    user = User.where(active: true, deleted_at: nil)
               .find_by('LOWER(email) = ?', token.identifier.downcase)
    return redirect_with_alert('Аккаунт не найден.') if user.nil?

    # Devise остаётся подключён в User model (только routes/controllers off).
    # user.password= вызывает Devise hashing (BCrypt + pepper). Skip
    # current_password validation — это reset-flow, не change-password.
    user.password = password
    user.password_confirmation = confirm
    unless user.save
      @token = token
      flash.now[:alert] = "Не удалось установить пароль: #{user.errors.full_messages.join('; ')}"
      render :edit, status: :unprocessable_entity and return
    end

    unless token.consume!
      flash[:alert] = 'Ссылка уже использована. Запросите новую.'
      redirect_to cabinet_login_path and return
    end

    reset_session
    session[:cabinet_user_id] = user.id
    flash[:notice] = 'Пароль обновлён. Вы вошли в кабинет.'
    redirect_to cabinet_path
  end

  private

  def find_valid_token(raw)
    return nil if raw.blank?

    MagicLinkToken.valid.where(scope: 'password_reset').find_by(token: raw)
  end

  def redirect_with_alert(msg)
    flash[:alert] = msg
    redirect_to new_cabinet_password_path
  end

  def enforce_rate_limit
    return false unless defined?(Redis)

    key = "cabinet:password_reset:#{request.remote_ip}"
    redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://redis:6379/1'))
    count = redis.incr(key)
    redis.expire(key, RATE_LIMIT[:window].to_i) if count == 1
    return if count <= RATE_LIMIT[:count]

    flash[:alert] = 'Слишком много запросов. Попробуйте через час.'
    redirect_to cabinet_login_path
  rescue Redis::BaseError => e
    Rails.logger.warn("[Cabinet::Passwords] rate-limit Redis error: #{e.message}")
    nil
  end
end
