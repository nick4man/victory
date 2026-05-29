# frozen_string_literal: true

# Phase 3b partner portal authentication. Magic-link via email only
# (partners — это организации, у которых canonical contact = email).
#
# Mirrors Cabinet::AuthController но scope-isolated:
#   - MagicLinkToken.scope = 'partner_login'
#   - session[:partner_agency_id] (отдельно от cabinet_user_id)
#
# Rate limit: 5/час per IP (same как cabinet).
module Partners
  class AuthController < ApplicationController
    RATE_LIMIT = { count: 5, window: 1.hour }.freeze
    EMAIL_REGEX = URI::MailTo::EMAIL_REGEXP

    before_action :enforce_rate_limit, only: :create

    def new
      redirect_to partners_path and return if session[:partner_agency_id].present?
    end

    # POST /partners/login — request magic-link
    def create
      email = params[:email].to_s.strip.downcase
      if email.blank? || !email.match?(EMAIL_REGEX)
        flash.now[:alert] = 'Введите корректный email агентства.'
        @email_prefill = email
        render :new, status: :unprocessable_entity and return
      end

      agency = PartnerAgency.where(status: 'active').find_by('LOWER(contact_email) = ?', email)
      token = MagicLinkToken.generate!(
        identifier:      email,
        identifier_type: 'email',
        scope:           'partner_login',
        request:         request
      )

      # ВСЕГДА отправляем письмо (даже если agency не найдено) — security:
      # не leak'аем whether email registered. Если нет matching agency,
      # CabinetMailer.partner_magic_link шлёт plain notification без linka.
      if agency.present?
        PartnerInvitationMailer.magic_link(agency, token).deliver_later
        Rails.logger.info("[Partners::Auth] sent magic-link agency=#{agency.slug} token=***")
      else
        Rails.logger.info("[Partners::Auth] login attempt email=#{email[0..2]}*** no matching agency")
      end

      flash[:notice] = 'Если email зарегистрирован — ссылка отправлена. Действует 30 минут.'
      redirect_to partners_login_path
    end

    # GET /partners/verify/:token
    def verify
      token = MagicLinkToken.valid.where(scope: 'partner_login').find_by(token: params[:token])
      if token.nil?
        flash[:alert] = 'Ссылка истекла или уже использована. Запросите новую.'
        redirect_to partners_login_path and return
      end

      agency = PartnerAgency.where(status: 'active').find_by('LOWER(contact_email) = ?', token.identifier)
      if agency.nil?
        flash[:alert] = 'Партнёр не найден или деактивирован.'
        redirect_to partners_login_path and return
      end

      token.update!(consumed_at: Time.current)
      agency.update_columns(last_login_at: Time.current)
      session[:partner_agency_id] = agency.id
      redirect_to partners_path, notice: "Добро пожаловать, #{agency.name}."
    end

    # DELETE /partners/logout
    def destroy
      session.delete(:partner_agency_id)
      redirect_to partners_login_path, notice: 'Вы вышли из портала партнёра.'
    end

    private

    def enforce_rate_limit
      key = "partner:link_request:#{request.remote_ip}"
      ttl = RATE_LIMIT[:window].to_i
      count = Rails.cache.read(key).to_i
      if count >= RATE_LIMIT[:count]
        flash.now[:alert] = "Слишком много запросов. Попробуйте через #{RATE_LIMIT[:window].inspect}."
        render :new, status: :too_many_requests and return
      end
      Rails.cache.write(key, count + 1, expires_in: ttl)
    end
  end
end
