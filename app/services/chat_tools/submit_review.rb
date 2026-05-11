# frozen_string_literal: true

module ChatTools
  # Bot accepts a customer review during chat. Always lands as `pending`;
  # Admin::ReviewsController#approve makes it public. Notifies moderator
  # via Telegram (or email fallback) so Oksana sees new submissions in real time.
  module SubmitReview
    def self.schema
      {
        type: 'function',
        function: {
          name: 'submit_review',
          description: 'Принимает отзыв клиента в систему модерации. ' \
                       'Вызывай ТОЛЬКО когда пользователь явно подтвердил: "давайте отправим/отправляйте/да публикуйте". ' \
                       'Обязательно собрать имя, оценку 1-5 и текст 10-1000 символов в диалоге ДО вызова.',
          parameters: {
            type: 'object',
            required: %w[author_name rating body],
            properties: {
              author_name: {
                type: 'string',
                description: 'Имя клиента (как подписать отзыв на сайте). Минимум 2 символа.'
              },
              rating: {
                type: 'integer',
                description: 'Оценка 1-5 звёзд, где 5 — лучше всего',
                enum: [1, 2, 3, 4, 5]
              },
              body: {
                type: 'string',
                description: 'Текст отзыва, 10-1000 символов'
              },
              title: {
                type: 'string',
                description: 'Опциональный заголовок отзыва'
              },
              email: {
                type: 'string',
                description: 'Опциональный email клиента — не публикуется, только для связи'
              },
              phone: {
                type: 'string',
                description: 'Опциональный телефон клиента — не публикуется, только для связи'
              },
              property_slug: {
                type: 'string',
                description: 'Опциональный slug объекта (если отзыв привязан к конкретной квартире/дому)'
              }
            },
            additionalProperties: false
          }
        }
      }
    end

    def self.call(args)
      args = args.to_h.transform_keys(&:to_sym)

      property = if args[:property_slug].present?
                   Property.unscoped.friendly.find(args[:property_slug]) rescue nil
                 end

      review = Review.new(
        author_name:   sanitize_short(args[:author_name], 80),
        author_email:  sanitize_short(args[:email], 200),
        author_phone:  sanitize_short(args[:phone], 40),
        rating:        args[:rating].to_i,
        title:         sanitize_short(args[:title], 200),
        body:          sanitize_long(args[:body], 1000),
        property_id:   property&.id,
        status:        :pending,
        source:        'own',
        submitted_via: 'chat_bot'
      )

      if review.save
        notify_moderator(review)
        {
          success:  true,
          review_id: review.id,
          message:   'Отзыв принят и отправлен на модерацию. После одобрения он появится на сайте (обычно в течение суток). Спасибо!'
        }
      else
        {
          success: false,
          errors:  review.errors.full_messages
        }
      end
    end

    def self.sanitize_short(value, max)
      ChatTools::Format.sanitize_text(value.to_s).strip.truncate(max)
    end

    def self.sanitize_long(value, max)
      ChatTools::Format.sanitize_text(value.to_s).strip.truncate(max, omission: '')
    end

    def self.notify_moderator(review)
      ReviewModerationNotifier.notify(review)
    rescue StandardError => e
      Rails.logger.warn("[SubmitReview] notifier failed: #{e.class} #{e.message}")
    end
  end
end
