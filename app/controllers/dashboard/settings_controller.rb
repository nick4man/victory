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

  def update_notification_settings
    settings = params.permit(notification_settings: {}).to_h[:notification_settings] || {}
    current_user.update(notification_settings: settings)
    redirect_to notifications_dashboard_settings_path, notice: 'Настройки уведомлений сохранены'
  end

  private

  def settings_params
    params.require(:user).permit(:email, :phone, :locale, :time_zone)
  end
end
