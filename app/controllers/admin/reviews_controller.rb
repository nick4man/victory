# frozen_string_literal: true

module Admin
  # Token-guarded review moderation. Authentication via AdminTokenAuth
  # (either `?token=…` URL param or the session cookie set after
  # /admin/login). Replace with a Pundit policy when proper roles return.
  class ReviewsController < ApplicationController
    include AdminTokenAuth
    layout 'application'
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
      redirect_back fallback_location: admin_reviews_path, notice: 'Отзыв одобрен.'
    end

    def reject
      @review.reject!(params[:reason].presence)
      AgencyMetricsService.bust!
      redirect_back fallback_location: admin_reviews_path, notice: 'Отзыв отклонён.'
    end

    private

    def set_review
      @review = Review.find(params[:id])
    end
  end
end
