# frozen_string_literal: true

module Dashboard
  class MessagesController < BaseController
    def index
      render_coming_soon('Сообщения')
    end

    def show
      render_coming_soon('Сообщение')
    end

    def create
      redirect_to dashboard_messages_path, notice: 'Сообщение отправлено.'
    end

    def unread
      render_coming_soon('Непрочитанные')
    end

    def mark_all_read
      head :ok
    end

    def mark_read
      head :ok
    end
  end
end
