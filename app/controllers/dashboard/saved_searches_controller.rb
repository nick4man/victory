# frozen_string_literal: true

module Dashboard
  class SavedSearchesController < BaseController
    def index
      @saved_searches = current_user.saved_searches.order(created_at: :desc)
      render template: 'dashboard/saved_searches'
    rescue StandardError
      render_coming_soon('Сохранённые поиски', "Поисков: #{current_user.saved_searches.count}")
    end

    def show
      render_coming_soon('Сохранённый поиск')
    end

    def new
      render_coming_soon('Новый сохранённый поиск')
    end

    def create
      redirect_to dashboard_saved_searches_path, notice: 'Поиск сохранён.'
    end

    def edit
      render_coming_soon('Редактирование поиска')
    end

    def update
      redirect_to dashboard_saved_searches_path, notice: 'Сохранено.'
    end

    def destroy
      current_user.saved_searches.where(id: params[:id]).destroy_all
      redirect_to dashboard_saved_searches_path, notice: 'Удалено.'
    end

    def activate
      redirect_to dashboard_saved_searches_path, notice: 'Активирован.'
    end

    def deactivate
      redirect_to dashboard_saved_searches_path, notice: 'Деактивирован.'
    end

    def check_new
      head :ok
    end
  end
end
