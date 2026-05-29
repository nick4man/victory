# frozen_string_literal: true

module Sms
  # Provider router. Реализация выбирается через ENV['SMS_PROVIDER']:
  #   'smsru' (default) — Sms::SmsRuClient   (~40–50% дешевле)
  #   'smsc'            — Sms::SmscClient   (legacy/fallback)
  #
  # API совместимый Result interface — каллеры не знают какой провайдер.
  #
  # Usage:
  #   result = Sms::Client.send(phone: '+79091234567', message: 'Hi')
  #   if result.success?
  #     # result.message_id, result.cost
  #   else
  #     # result.error
  #   end
  class Client
    DEFAULT_PROVIDER = 'smsru'

    def self.send(phone:, message:, sender: nil)
      provider = ENV.fetch('SMS_PROVIDER', DEFAULT_PROVIDER).to_s.downcase
      case provider
      when 'smsru' then SmsRuClient.send(phone: phone, message: message, sender: sender)
      when 'smsc'  then SmscClient.send(phone: phone, message: message, sender: sender)
      else
        Rails.logger.warn("[Sms::Client] unknown SMS_PROVIDER=#{provider.inspect} — defaulting to smsru")
        SmsRuClient.send(phone: phone, message: message, sender: sender)
      end
    end
  end
end
