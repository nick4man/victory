# frozen_string_literal: true

# Admin Mailer — служебные уведомления администраторам сайта.
class AdminMailer < ApplicationMailer
  # Жалоба на объект с публичной страницы (POST /properties/:id/report).
  # До #262 экшен ссылался на несуществующий mailer и каждая жалоба падала
  # с NameError; mailer добавлен вместе с антиспам-гейтом эндпоинта.
  # @param property [Property]
  # @param reporter [User, nil] — Devise выключен, обычно nil
  def property_reported(property, reporter, reason, description)
    @property = property
    @reporter = reporter
    @reason = reason
    @description = description

    attach_logo

    mail(
      to: ENV.fetch('ADMIN_EMAIL', 'admin@viktory-realty.ru'),
      subject: "[Жалоба] #{property.title} — #{reason}"
    )
  end
end
