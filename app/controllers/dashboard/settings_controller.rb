# frozen_string_literal: true

class Dashboard::SettingsController < Dashboard::BaseController
  def show
  end

  def update
    if current_user.update(settings_params)
      redirect_to dashboard_settings_path, notice: 'Настройки сохранены'
    else
      render :show, status: :unprocessable_entity
    end
  end

  def notification_settings
    render :show
  end

  ALLOWED_NOTIFICATION_KEYS = %i[
    new_properties price_changes new_messages inquiry_updates
    saved_search_results viewing_reminders newsletter
  ].freeze

  def update_notification_settings
    raw = params.permit(notification_settings: ALLOWED_NOTIFICATION_KEYS)
                .to_h.fetch('notification_settings', {})
    # Приводим значения к булевым, игнорируя любые другие типы
    settings = raw.transform_values { |v| ActiveModel::Type::Boolean.new.cast(v) }
    current_user.update(notification_settings: settings)
    redirect_to notifications_dashboard_settings_path, notice: 'Настройки уведомлений сохранены'
  end

  private

  def settings_params
    params.require(:user).permit(:email, :phone, :locale, :time_zone)
  end
end
