# frozen_string_literal: true

class Dashboard::HomeController < Dashboard::BaseController
  def index
    @properties = current_user.properties.order(created_at: :desc).limit(5)
    @favorites_count = current_user.favorites.count
    @inquiries_count = current_user.inquiries.count
  end
end
