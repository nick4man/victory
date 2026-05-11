# frozen_string_literal: true

module Admin
  # Token-guarded review moderation. Lives outside the Devise authenticate
  # block in routes.rb because Devise is currently disabled in this app
  # (see CLAUDE.md). Replace token check with a Pundit policy when auth
  # comes back online.
  class ReviewsController < ApplicationController
    layout 'application'
    before_action :require_admin_token
    before_action :set_review, only: %i[show approve reject]

    def index
      scope = Review.all.includes(:property, :user)
      scope = scope.where(status: Review.statuses[params[:status]]) if params[:status].present?
      @reviews = scope.recent.page(params[:page]).per(50)
    end

    def show; end

    def approve
      @review.approve!
      AgencyMetricsService.bust!
      redirect_back fallback_location: admin_reviews_path(token: params[:token]), notice: 'Отзыв одобрен.'
    end

    def reject
      @review.reject!(params[:reason].presence)
      AgencyMetricsService.bust!
      redirect_back fallback_location: admin_reviews_path(token: params[:token]), notice: 'Отзыв отклонён.'
    end

    private

    def set_review
      @review = Review.find(params[:id])
    end

    def require_admin_token
      expected = ENV['ADMIN_TOKEN']
      if expected.blank?
        head :forbidden and return
      end
      head :forbidden and return unless ActiveSupport::SecurityUtils.secure_compare(params[:token].to_s, expected)
    end
  end
end
