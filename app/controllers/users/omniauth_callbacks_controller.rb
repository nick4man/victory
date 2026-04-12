# frozen_string_literal: true

class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  # Google OAuth2
  def google_oauth2
    handle_auth('Google')
  end

  def failure
    redirect_to new_user_session_path,
                alert: "Аутентификация через #{failed_strategy.name.capitalize} не удалась. Попробуйте снова."
  end

  private

  def handle_auth(provider_name)
    @user = User.from_omniauth(request.env['omniauth.auth'])

    if @user.persisted?
      sign_in_and_redirect @user, event: :authentication
      set_flash_message(:notice, :success, kind: provider_name) if is_navigational_format?
    else
      session['devise.omniauth_data'] = request.env['omniauth.auth'].except(:extra)
      redirect_to new_user_registration_url,
                  alert: @user.errors.full_messages.join(', ')
    end
  end
end
