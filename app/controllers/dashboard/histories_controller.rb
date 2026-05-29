# frozen_string_literal: true

module Dashboard
  class HistoriesController < BaseController
    def index
      @viewed = current_user.property_views.includes(:property).order(viewed_at: :desc).limit(50)
      render_coming_soon('История просмотров', "Просмотрено объектов: #{@viewed.size}")
    rescue StandardError
      render_coming_soon('История просмотров')
    end

    def clear
      current_user.property_views.destroy_all
      redirect_to dashboard_history_index_path, notice: 'История очищена.'
    end
  end
end
