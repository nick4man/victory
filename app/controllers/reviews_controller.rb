# frozen_string_literal: true

class ReviewsController < ApplicationController
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
    # #261: подписанный timestamp рендера — без него POST дропается гейтом.
    @rendered_at_token = PublicFormSpamGate.rendered_at_token
    set_meta_tags(title: 'Оставить отзыв — АН «Виктори»', robots: 'noindex,follow')
  end

  def create
    result = review_spam_gate.call

    if result.spam
      # #261: молчаливый дроп (образец #255) — бот не должен узнать, что
      # его раскрыли: success-ответ, без записи, без пинга модерации.
      review_spam_gate.record(ua: request.user_agent)
      redirect_to reviews_path, notice: I18n.t('messages.review_accepted')
      return
    end

    @review = Review.new(review_params)
    @review.assign_attributes(
      status:        :pending,
      source:        'own',
      submitted_via: 'web_form',
      ip_address:    request.remote_ip,
      user_agent:    ContactFormSpamGuard.sanitize_user_agent(request.user_agent)
    )

    if @review.save
      # Счётчик rate limit растёт только по реально сохранённым отзывам:
      # невалидный повтор не должен израсходовать чей-то лимит.
      review_spam_gate.register_rate_limit_hit!
      ReviewModerationNotifier.notify(@review) rescue nil
      redirect_to reviews_path, notice: I18n.t('messages.review_accepted')
    else
      flash.now[:alert] = 'Не удалось сохранить отзыв. Проверьте поля и попробуйте ещё раз.'
      # Повторная отправка после правки полей должна пройти гейт:
      # перевыпускаем timestamp рендера для отрисованной заново формы.
      @rendered_at_token = PublicFormSpamGate.rendered_at_token
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

  def review_spam_gate
    PublicFormSpamGate.new(
      form:          'review',
      honeypot:      params[PublicFormSpamGate::HONEYPOT_PARAM],
      rendered_at:   params[:rendered_at_token],
      ip:            request.remote_ip,
      visitor_token: current_visitor_token
    )
  end
end
