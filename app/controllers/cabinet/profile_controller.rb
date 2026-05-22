# frozen_string_literal: true

module Cabinet
  # Профиль клиента в личном кабинете. Содержит TG opt-in flow и
  # self-service (пароль / email / phone / удаление аккаунта).
  #
  # Routes:
  #   GET    /cabinet/profile                       → show
  #   GET    /cabinet/profile/edit                  → edit (self-service form)
  #   POST   /cabinet/profile/password              → update_password
  #   POST   /cabinet/profile/email                 → request_email_change (verify-link → NEW email)
  #   GET    /cabinet/profile/email/verify/:token   → confirm_email_change
  #   POST   /cabinet/profile/phone                 → request_phone_change (SMS code → NEW phone)
  #   POST   /cabinet/profile/phone/verify          → confirm_phone_change
  #   DELETE /cabinet/profile/account               → destroy_account (152-ФЗ §21)
  #   POST   /cabinet/profile/tg/link               → start TG opt-in flow
  #   DELETE /cabinet/profile/tg/link               → unlink TG
  class ProfileController < ApplicationController
    before_action :require_client_cabinet_user, except: [:confirm_email_change]

    def show
      @tg_linked = @cabinet_user.tg_user_id.present?
      @bot_username = (ENV['TELEGRAM_BOT_USERNAME'].presence || 'anvictorybot').downcase
    end

    def edit
      @has_password = @cabinet_user.encrypted_password.present?
    end

    # POST /cabinet/profile/password
    # Update or set password (no current_password required — session уже
    # authenticated). 8-char minimum, confirmation match.
    def update_password
      password = params[:password].to_s
      confirm  = params[:password_confirmation].to_s

      if password.length < 8
        flash[:alert] = 'Пароль должен быть не короче 8 символов.'
        redirect_to edit_cabinet_profile_path and return
      end
      if password != confirm
        flash[:alert] = 'Пароли не совпадают.'
        redirect_to edit_cabinet_profile_path and return
      end

      @cabinet_user.password = password
      @cabinet_user.password_confirmation = confirm
      if @cabinet_user.save
        Rails.logger.info("[Cabinet::Profile] password updated user=#{@cabinet_user.id}")
        redirect_to cabinet_profile_path, notice: 'Пароль обновлён.'
      else
        flash[:alert] = "Не удалось: #{@cabinet_user.errors.full_messages.join('; ')}"
        redirect_to edit_cabinet_profile_path
      end
    end

    # POST /cabinet/profile/email
    # Sends magic-link verify к НОВОМУ email. Текущий email не меняется
    # пока пользователь не consume'нёт token (защита от случайного отказа).
    def request_email_change
      new_email = params[:email].to_s.strip.downcase
      if new_email.blank? || !new_email.match?(URI::MailTo::EMAIL_REGEXP)
        flash[:alert] = 'Введите корректный email.'
        redirect_to edit_cabinet_profile_path and return
      end
      if new_email == @cabinet_user.email.to_s.downcase
        flash[:alert] = 'Этот email уже привязан к вашему аккаунту.'
        redirect_to edit_cabinet_profile_path and return
      end
      if User.where(deleted_at: nil, active: true).where('LOWER(email) = ?', new_email).exists?
        flash[:alert] = 'Этот email уже занят другим пользователем.'
        redirect_to edit_cabinet_profile_path and return
      end

      token = MagicLinkToken.generate!(
        identifier:      new_email,
        identifier_type: 'email',
        scope:           'email_change',
        request:         request
      )
      # Метаданные: в identifier хранится НОВЫЙ email, ip_address уже set.
      # Но нужно знать какой User инициировал — сохраняем в session, чтобы
      # на confirm понимать кого update'ить (token leak к чужому email
      # не даёт hijack ничего — confirm проверяет session current user).
      session[:pending_email_change_user_id] = @cabinet_user.id

      CabinetMailer.email_change_confirmation(@cabinet_user, new_email, token).deliver_later
      Rails.logger.info(
        "[Cabinet::Profile] email_change requested user=#{@cabinet_user.id} " \
        "to=#{new_email[0..2]}*** "
      )
      redirect_to cabinet_profile_path,
                  notice: "Ссылка для подтверждения отправлена на #{new_email}. Откройте её с того же устройства (30 мин)."
    end

    # GET /cabinet/profile/email/verify/:token
    # Confirm email change. Гейтов нет — клик по ссылке = подтверждение
    # владения inbox'ом, а pending_email_change_user_id в session
    # гарантирует что это тот же user который инициировал.
    def confirm_email_change
      token = MagicLinkToken.valid.where(scope: 'email_change').find_by(token: params[:token])
      pending_uid = session[:pending_email_change_user_id]

      if token.nil? || pending_uid.blank?
        flash[:alert] = 'Ссылка недействительна, истекла или запрос не из этой сессии.'
        redirect_to cabinet_login_path and return
      end

      user = User.find_by(id: pending_uid, deleted_at: nil, active: true)
      if user.nil?
        flash[:alert] = 'Аккаунт не найден.'
        redirect_to cabinet_login_path and return
      end

      new_email = token.identifier
      if User.where(deleted_at: nil, active: true).where('LOWER(email) = ?', new_email).where.not(id: user.id).exists?
        flash[:alert] = 'Email уже занят. Запросите смену на другой адрес.'
        redirect_to cabinet_profile_path and return
      end

      old_email = user.email
      user.update_columns(email: new_email)
      token.consume!
      session.delete(:pending_email_change_user_id)
      Rails.logger.info(
        "[Cabinet::Profile] email_change confirmed user=#{user.id} " \
        "old=#{old_email&.first(3)}*** new=#{new_email[0..2]}***"
      )
      redirect_to cabinet_profile_path, notice: 'Email обновлён.'
    end

    # POST /cabinet/profile/phone
    # SMS с 6-значным кодом на НОВЫЙ телефон. Шлёт ОДИН SMS — это
    # transactional verify, не recurring рассылка.
    def request_phone_change
      new_phone = normalize_phone(params[:phone].to_s)
      if new_phone.blank? || new_phone.length < 10
        flash[:alert] = 'Введите корректный телефон (минимум 10 цифр).'
        redirect_to edit_cabinet_profile_path and return
      end
      if new_phone == normalize_phone(@cabinet_user.phone.to_s)
        flash[:alert] = 'Этот телефон уже привязан к вашему аккаунту.'
        redirect_to edit_cabinet_profile_path and return
      end
      if PhoneStopList.blocked?(new_phone)
        flash[:alert] = 'Этот номер в списке исключений (152-ФЗ). Свяжитесь с агентом.'
        redirect_to edit_cabinet_profile_path and return
      end

      code = SecureRandom.random_number(900_000) + 100_000 # 6 digits
      token = MagicLinkToken.generate!(
        identifier:      new_phone,
        identifier_type: 'phone',
        scope:           'phone_change',
        request:         request
      )
      # Store 6-digit code в session (не в token — token public, code secret)
      session[:phone_change_code]    = code.to_s
      session[:phone_change_token_id] = token.id
      session[:phone_change_user_id]  = @cabinet_user.id

      result = Sms::Client.send(
        phone:   new_phone,
        message: "АН Виктори: ваш код подтверждения телефона — #{code}. " \
                 'Если вы не запрашивали смену, проигнорируйте это сообщение.'
      )
      unless result.success?
        Rails.logger.warn("[Cabinet::Profile] phone change SMS failed: #{result.error}")
        flash[:alert] = "Не удалось отправить SMS: #{result.error}."
        redirect_to edit_cabinet_profile_path and return
      end

      Rails.logger.info("[Cabinet::Profile] phone_change SMS sent user=#{@cabinet_user.id}")
      redirect_to edit_cabinet_profile_path,
                  notice: "Код отправлен на #{new_phone}. Введите его ниже (срок 30 мин)."
    end

    # POST /cabinet/profile/phone/verify
    def confirm_phone_change
      code = params[:code].to_s.strip
      expected = session[:phone_change_code]
      token_id = session[:phone_change_token_id]
      user_id  = session[:phone_change_user_id]

      if expected.blank? || token_id.blank? || user_id != @cabinet_user.id
        flash[:alert] = 'Запрос на смену телефона не активен.'
        redirect_to edit_cabinet_profile_path and return
      end

      if code != expected
        flash[:alert] = 'Неверный код. Запросите новый.'
        redirect_to edit_cabinet_profile_path and return
      end

      token = MagicLinkToken.find_by(id: token_id, scope: 'phone_change')
      if token.nil? || token.consumed_at.present? || token.expires_at < Time.current
        flash[:alert] = 'Код истёк. Запросите новый.'
        redirect_to edit_cabinet_profile_path and return
      end

      old_phone = @cabinet_user.phone
      @cabinet_user.update_columns(phone: token.identifier)
      token.consume!
      session.delete(:phone_change_code)
      session.delete(:phone_change_token_id)
      session.delete(:phone_change_user_id)

      Rails.logger.info(
        "[Cabinet::Profile] phone_change confirmed user=#{@cabinet_user.id} " \
        "old=***#{old_phone.to_s.last(4)} new=***#{token.identifier.last(4)}"
      )
      redirect_to cabinet_profile_path, notice: 'Телефон обновлён.'
    end

    # DELETE /cabinet/profile/account
    # 152-ФЗ §21 — soft-delete + anonymize PII + revoke all tokens.
    # Audit-trail (User.id + deleted_at) сохраняется — нельзя hard-delete,
    # т.к. Inquiry/PropertyValuation ссылаются на user_id.
    def destroy_account
      confirm = params[:confirm].to_s.strip.downcase
      unless confirm == 'удалить'
        flash[:alert] = 'Подтвердите слово «удалить» в форме.'
        redirect_to edit_cabinet_profile_path and return
      end

      user = @cabinet_user
      User.transaction do
        # Revoke all valid tokens (login + email_change + phone_change)
        MagicLinkToken.where(identifier: [user.email.to_s.downcase, user.phone.to_s])
                      .where(consumed_at: nil)
                      .update_all(consumed_at: Time.current)
        TgLinkToken.where(user_id: user.id).where(consumed_at: nil)
                   .update_all(consumed_at: Time.current)

        # Anonymize PII per 152-ФЗ §21 (right to be forgotten, но с
        # сохранением audit-trail для аналитики/legal req на 5 лет).
        # Email/encrypted_password — NOT NULL constraint в БД, поэтому
        # ставим placeholder (non-routable .deleted домен / пустой пароль).
        # Phone — nullable, можно nil.
        user.update_columns(
          first_name:         'Удалённый',
          last_name:          'пользователь',
          middle_name:        nil,
          email:              "deleted-#{user.id}@victory62.deleted",
          phone:              nil,
          encrypted_password: '',
          tg_user_id:         nil,
          tg_username:        nil,
          tg_linked_at:       nil,
          active:             false,
          deleted_at:         Time.current
        )
      end

      Rails.logger.info("[Cabinet::Profile] account deleted user=#{user.id} (anonymized + soft-deleted)")
      reset_session
      flash[:notice] = 'Аккаунт удалён. Все ваши данные обезличены. До свидания!'
      redirect_to root_path
    end

    # POST /cabinet/profile/tg/link
    # Идемпотентно: если уже linked — просто редирект назад с notice.
    # Иначе — генерируем 30-min token + redirect на TG deep-link.
    def link_telegram
      if @cabinet_user.tg_user_id.present?
        redirect_to cabinet_profile_path, notice: 'Telegram уже подключён.'
        return
      end

      token = TgLinkToken.generate!(user: @cabinet_user, request: request, source: 'cabinet_profile')
      bot_username = (ENV['TELEGRAM_BOT_USERNAME'].presence || 'anvictorybot').downcase

      Rails.logger.info("[Cabinet::Profile] tg_link initiated user=#{@cabinet_user.id}")
      redirect_to "https://t.me/#{bot_username}?start=#{token.token}",
                  allow_other_host: true
    end

    # DELETE /cabinet/profile/tg/link
    # Отвязка TG — клиент может re-link при желании. Соблюдаем 152-ФЗ
    # (right to disconnect a binding channel).
    def unlink_telegram
      previous_tg = @cabinet_user.tg_user_id
      @cabinet_user.update_columns(
        tg_user_id:   nil,
        tg_username:  nil,
        tg_linked_at: nil
      )
      Rails.logger.info("[Cabinet::Profile] tg_unlinked user=#{@cabinet_user.id} (was=#{previous_tg})")
      redirect_to cabinet_profile_path, notice: 'Telegram отключён. Уведомления будут приходить по SMS / email.'
    end

    private

    def require_client_cabinet_user
      @cabinet_user = current_cabinet_user
      return if @cabinet_user&.role_client?

      redirect_to cabinet_login_path, alert: 'Доступ только для клиентов в личном кабинете.'
    end

    def normalize_phone(raw)
      digits = raw.to_s.gsub(/\D/, '')
      return nil if digits.empty?
      digits.start_with?('7', '8') ? "+7#{digits[-10..]}" : "+#{digits}"
    end
  end
end
