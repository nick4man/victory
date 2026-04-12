# frozen_string_literal: true

class ReviewsController < ApplicationController
  def index
    @reviews = []
  end

  def create
    render json: { success: true, message: 'Отзыв отправлен на модерацию' }
  end
end
