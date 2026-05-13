# frozen_string_literal: true

module Dashboard
  # Single-page settings — three sections on one form:
  #   1. Notifications (which emails / TG messages the user wants)
  #   2. Security (links to Devise pages for email/password change)
  #   3. Delete account (soft-delete via User#soft_delete!)
  #
  # `update` merges submitted notification toggles into the user's existing
  # jsonb so we never wipe unknown keys (other features may write there).
  class SettingsController < BaseController
    DEFAULT_NOTIFICATION_KEYS = %w[
      email_new_inquiry
      email_inquiry_status
      email_valuation_ready
      email_property_match
      email_newsletter
    ].freeze

    def show
      @notifications = current_notifications
    end

    def update
      merged = current_notifications.merge(submitted_notifications)
      if current_user.update(notification_settings: merged)
        redirect_to dashboard_settings_path, notice: 'Настройки уведомлений сохранены.'
      else
        @notifications = merged
        render :show, status: :unprocessable_entity
      end
    end

    # Legacy routes still point here — both alias to the main page.
    def notification_settings
      redirect_to dashboard_settings_path
    end

    def update_notification_settings
      update
    end

    # DELETE /dashboard/settings/account — soft-delete the user. Email is
    # preserved (NOT NULL constraint), but `deleted_at` is set, which blocks
    # future sign-in via User#active_for_authentication?. We sign out first
    # so the session cookie no longer maps to a live user.
    def destroy_account
      user = current_user
      sign_out user
      user.soft_delete!
      redirect_to root_path,
                  notice: 'Аккаунт удалён. Если передумаете — напишите нам, восстановим в течение 30 дней.'
    end

    private

    def current_notifications
      base = DEFAULT_NOTIFICATION_KEYS.index_with { true }
      stored = current_user.notification_settings || {}
      base.merge(stored)
    end

    # Form checkboxes only arrive in params when CHECKED. Translate the
    # submission into an explicit-true/false hash so unchecking a box
    # records `false` instead of silently keeping the old value.
    def submitted_notifications
      submitted = params[:notifications]&.permit!&.to_h || {}
      DEFAULT_NOTIFICATION_KEYS.index_with { |k| submitted[k] == '1' }
    end
  end
end
