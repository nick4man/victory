# frozen_string_literal: true

module Dashboard
  # In-app notification feed. Reads from the Notification model — every
  # mailer/job that wants to alert the user calls `Notification.notify!`
  # and the entry shows up here in real time.
  class NotificationsController < BaseController
    def index
      @notifications = current_user.notifications.not_archived.recent.page(params[:page]).per(30)
      @unread_count  = current_user.notifications.unread.not_archived.count
    end

    # POST /dashboard/notifications/mark_all_read
    def mark_all_read
      current_user.notifications.unread.update_all(read_at: Time.current)
      respond_to do |format|
        format.html { redirect_to dashboard_notifications_path, notice: 'Все уведомления прочитаны.' }
        format.json { head :ok }
      end
    end

    # POST /dashboard/notifications/:id/mark_read
    def mark_read
      notification = current_user.notifications.find(params[:id])
      notification.mark_read!
      respond_to do |format|
        format.html { redirect_to(notification.url.presence || dashboard_notifications_path) }
        format.json { head :ok }
      end
    end

    # DELETE /dashboard/notifications/clear_all — archives every notification.
    # We never hard-delete (audit / analytics keep history).
    def clear_all
      current_user.notifications.not_archived.update_all(archived_at: Time.current)
      redirect_to dashboard_notifications_path, notice: 'Уведомления очищены.'
    end
  end
end
