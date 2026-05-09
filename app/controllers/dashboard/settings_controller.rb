# frozen_string_literal: true

module Dashboard
  class SettingsController < BaseController
    def show
      render_coming_soon('Настройки')
    end

    def update
      redirect_to dashboard_settings_path, notice: 'Сохранено.'
    end

    def notification_settings
      render_coming_soon('Настройки уведомлений')
    end

    def update_notification_settings
      redirect_to notifications_dashboard_settings_path, notice: 'Настройки сохранены.'
    end
  end
end
