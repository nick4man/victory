# frozen_string_literal: true

module Dashboard
  class FavoritesController < BaseController
    def index
      @favorites = current_user.favorites.includes(:property).order(created_at: :desc)
      render template: 'dashboard/favorites'
    rescue StandardError
      render_coming_soon('Избранное', "У вас #{current_user.favorites.count} объектов в избранном.")
    end

    def destroy
      current_user.favorites.where(id: params[:id]).destroy_all
      redirect_to dashboard_favorites_path, notice: 'Удалено.'
    end

    def clear_all
      current_user.favorites.destroy_all
      redirect_to dashboard_favorites_path, notice: 'Список очищен.'
    end

    def export
      send_data current_user.favorites.includes(:property).map { |f| [f.property_id, f.property&.title] }.to_csv,
                filename: "favorites-#{Time.current.to_i}.csv"
    rescue StandardError
      redirect_to dashboard_favorites_path, alert: 'Экспорт пока недоступен.'
    end
  end
end
