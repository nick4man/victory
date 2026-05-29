# frozen_string_literal: true

module Dashboard
  class HomeController < BaseController
    def index
      @user = current_user
      @favorites_count = current_user.favorites.count
      @inquiries_count = current_user.inquiries.count
      @viewed_count = current_user.property_views.count
      @recent_favorites = current_user.favorites.includes(:property).order(created_at: :desc).limit(5)
      @recent_inquiries = current_user.inquiries.order(created_at: :desc).limit(5)
      render template: 'dashboard/index'
    rescue StandardError
      render_coming_soon('Личный кабинет', 'Главная страница кабинета загружается. Если страница не появилась — раздел в разработке.')
    end
  end
end
