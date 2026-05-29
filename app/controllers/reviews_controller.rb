# frozen_string_literal: true

class ReviewsController < ApplicationController
  RATE_LIMIT_PER_HOUR = 3
  RATE_LIMIT_KEY      = 'review:submit:%<ip>s'

  def index
    @reviews   = Review.public_facing.page(params[:page]).per(12)
    @aggregate = AgencyMetricsService.call
    @new_review = Review.new
    set_meta_tags(
      title: 'Отзывы клиентов АН «Виктори»',
      description: 'Реальные отзывы наших клиентов о покупке, продаже и аренде недвижимости в Рязани. Средний рейтинг и истории сделок.'
    )
  end

  def new
    @review = Review.new
    set_meta_tags(title: 'Оставить отзыв — АН «Виктори»', robots: 'noindex,follow')
  end

  def create
    if rate_limited?
      flash[:alert] = "Можно оставить не более #{RATE_LIMIT_PER_HOUR} отзывов в час с одного устройства. Попробуйте позже."
      redirect_to(new_review_path) and return
    end

    @review = Review.new(review_params)
    @review.assign_attributes(
      status:        :pending,
      source:        'own',
      submitted_via: 'web_form',
      ip_address:    request.remote_ip,
      user_agent:    request.user_agent
    )

    if @review.save
      register_submission!
      ReviewModerationNotifier.notify(@review) rescue nil
      redirect_to reviews_path, notice: 'Спасибо! Отзыв принят и появится после модерации (обычно в течение суток).'
    else
      flash.now[:alert] = 'Не удалось сохранить отзыв. Проверьте поля и попробуйте ещё раз.'
      render :new, status: :unprocessable_entity
    end
  end

  def helpful
    head :ok
  end

  private

  def review_params
    params.require(:review).permit(:author_name, :author_email, :rating, :body, :title, :property_id)
  end

  def rate_limited?
    key = format(RATE_LIMIT_KEY, ip: request.remote_ip)
    count = Rails.cache.read(key).to_i
    count >= RATE_LIMIT_PER_HOUR
  end

  def register_submission!
    key = format(RATE_LIMIT_KEY, ip: request.remote_ip)
    Rails.cache.write(key, Rails.cache.read(key).to_i + 1, expires_in: 1.hour)
  end
end
