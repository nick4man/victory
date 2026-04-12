# frozen_string_literal: true

class Dashboard::HomeController < Dashboard::BaseController
  def index
    @properties = current_user.properties.order(created_at: :desc).limit(5)
    @favorites_count = current_user.favorites.count
    @inquiries_count = current_user.inquiries.count
    @unread_messages_count = current_user.unread_messages_count

    if current_user.agent? || current_user.admin?
      @active_properties_count = current_user.properties.where(status: :active).count
      @pending_properties_count = current_user.properties.where(status: :pending).count
      @draft_properties_count = current_user.properties.where(status: :draft).count
      @total_views = current_user.properties.sum(:views_count)
      @recent_inquiries = Inquiry.where(property: current_user.properties)
                                  .order(created_at: :desc).limit(5)
    end
  end
end
