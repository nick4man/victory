# frozen_string_literal: true

class Dashboard::NotificationsController < Dashboard::BaseController
  def index
    @notifications = []
  end

  def mark_read
    render json: { success: true }
  end

  def mark_all_read
    redirect_to dashboard_notifications_path, notice: 'Все уведомления прочитаны'
  end

  def clear_all
    redirect_to dashboard_notifications_path, notice: 'Уведомления очищены'
  end
end
