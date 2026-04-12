# frozen_string_literal: true

class Dashboard::HistoryController < Dashboard::BaseController
  def index
    @property_views = current_user.property_views.includes(:property).order(created_at: :desc).limit(50)
  end

  def clear
    current_user.property_views.destroy_all
    redirect_to dashboard_history_index_path, notice: 'История просмотров очищена'
  end
end
