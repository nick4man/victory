# frozen_string_literal: true

# Шлёт сотруднику АН 6-значный код подтверждения для команды /whoami
# в рабочем Telegram-боте. Код хранится в Rails.cache 15 мин (см.
# Telegram::WorkBot::Commands::Whoami).
class TelegramAuthMailer < ApplicationMailer
  def verification_code(email:, code:, tg_username:)
    @code = code
    @tg_username = tg_username
    @subject = 'Код подтверждения для Telegram-бота АН «Виктори»'
    mail(to: email, subject: @subject)
  end
end
