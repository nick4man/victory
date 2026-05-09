# frozen_string_literal: true

module Dashboard
  class ProfilesController < BaseController
    def show
      @user = current_user
      render_coming_soon('Профиль', "Здесь будут ваши данные: #{current_user.email}")
    end

    def edit
      render_coming_soon('Редактирование профиля')
    end

    def update
      redirect_to dashboard_profile_path, notice: 'Профиль обновлён.'
    end
  end
end
