# frozen_string_literal: true

module Dashboard
  class NotificationsController < BaseController
    def index
      render_coming_soon('Уведомления')
    end

    def mark_all_read
      head :ok
    end

    def clear_all
      redirect_to dashboard_notifications_path, notice: 'Очищено.'
    end

    def mark_read
      head :ok
    end
  end
end
