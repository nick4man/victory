# frozen_string_literal: true

module Admin
  # Lightweight login flow for the token-guarded admin area. No password,
  # no user record — just `ENV['ADMIN_TOKEN']` entered into a form and
  # the SHA256 digest stored in the encrypted session cookie. The cookie
  # is the only thing AdminTokenAuth#admin_authenticated? checks on
  # subsequent requests, so even shared screenshots of admin pages never
  # leak the raw token.
  class SessionsController < ApplicationController
    layout 'application'

    # GET /admin/login — show form. No auth required.
    def new
      @return_to = params[:return_to].presence
    end

    # POST /admin/login
    def create
      expected = ENV['ADMIN_TOKEN'].to_s
      submitted = params[:token].to_s

      if expected.blank?
        flash.now[:alert] = 'ADMIN_TOKEN не настроен на сервере.'
        render :new, status: :service_unavailable and return
      end

      submitted_digest = ::Digest::SHA256.hexdigest(submitted)
      expected_digest  = ::Digest::SHA256.hexdigest(expected)

      if ::ActiveSupport::SecurityUtils.secure_compare(submitted_digest, expected_digest)
        session[:admin_token_digest] = expected_digest
        target = sanitized_return_path(params[:return_to]) || admin_root_path
        redirect_to target, notice: 'Добро пожаловать в админку.'
      else
        @return_to = params[:return_to].presence
        flash.now[:alert] = 'Неверный токен.'
        render :new, status: :unauthorized
      end
    end

    # DELETE /admin/logout
    def destroy
      session.delete(:admin_token_digest)
      redirect_to root_path, notice: 'Сессия админа закрыта.'
    end

    private

    # Only allow same-origin internal paths to avoid open-redirect.
    def sanitized_return_path(value)
      return nil if value.blank?
      return nil unless value.to_s.start_with?('/')
      return nil if value.to_s.start_with?('//') # protocol-relative

      value
    end
  end
end
