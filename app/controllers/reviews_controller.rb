# frozen_string_literal: true

class ReviewsController < ApplicationController
  include ComingSoonSection

  def index
    render_coming_soon('Отзывы клиентов', 'Здесь будут отображаться отзывы наших клиентов.')
  end

  def create
    redirect_back fallback_location: root_path, notice: 'Спасибо за отзыв! Он появится после модерации.'
  end

  def helpful
    head :ok
  end
end
