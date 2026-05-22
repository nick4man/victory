# frozen_string_literal: true

module Cabinet
  # Профиль клиента в личном кабинете. Сейчас содержит TG opt-in flow;
  # дальше можно расширять (email-уведомления preferences, notification
  # channels, language, и т.п.).
  #
  # Routes:
  #   GET    /cabinet/profile          → show
  #   POST   /cabinet/profile/tg/link  → start TG opt-in flow (generates
  #                                       TgLinkToken, redirect на t.me/<bot>?start=<token>)
  #   DELETE /cabinet/profile/tg/link  → unlink (clears user.tg_user_id)
  class ProfileController < ApplicationController
    before_action :require_client_cabinet_user

    def show
      @tg_linked = @cabinet_user.tg_user_id.present?
      @bot_username = (ENV['TELEGRAM_BOT_USERNAME'].presence || 'anvictorybot').downcase
    end

    # POST /cabinet/profile/tg/link
    # Идемпотентно: если уже linked — просто редирект назад с notice.
    # Иначе — генерируем 30-min token + redirect на TG deep-link.
    def link_telegram
      if @cabinet_user.tg_user_id.present?
        redirect_to cabinet_profile_path, notice: 'Telegram уже подключён.'
        return
      end

      token = TgLinkToken.generate!(user: @cabinet_user, request: request)
      bot_username = (ENV['TELEGRAM_BOT_USERNAME'].presence || 'anvictorybot').downcase

      Rails.logger.info("[Cabinet::Profile] tg_link initiated user=#{@cabinet_user.id}")
      redirect_to "https://t.me/#{bot_username}?start=#{token.token}",
                  allow_other_host: true
    end

    # DELETE /cabinet/profile/tg/link
    # Отвязка TG — клиент может re-link при желании. Соблюдаем 152-ФЗ
    # (right to disconnect a binding channel).
    def unlink_telegram
      previous_tg = @cabinet_user.tg_user_id
      @cabinet_user.update_columns(
        tg_user_id:   nil,
        tg_username:  nil,
        tg_linked_at: nil
      )
      Rails.logger.info("[Cabinet::Profile] tg_unlinked user=#{@cabinet_user.id} (was=#{previous_tg})")
      redirect_to cabinet_profile_path, notice: 'Telegram отключён. Уведомления будут приходить по SMS / email.'
    end

    private

    def require_client_cabinet_user
      @cabinet_user = current_cabinet_user
      return if @cabinet_user&.role_client?

      redirect_to cabinet_login_path, alert: 'Доступ только для клиентов в личном кабинете.'
    end
  end
end
