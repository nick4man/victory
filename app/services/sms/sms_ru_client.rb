# frozen_string_literal: true

require 'net/http'
require 'json'

module Sms
  # SMS.ru API client — ~40–50% дешевле SMSC.ru при том же coverage (RU).
  # Public pricing 2026: 1.49–2.10 ₽/SMS (vs SMSC 2.49–3.99 ₽).
  #
  # Docs: https://sms.ru/api
  # Endpoint: https://sms.ru/sms/send
  # Auth: api_id (single token, не login+password как у SMSC)
  # JSON response (`json=1`):
  #   {"status":"OK","status_code":100,
  #    "sms":{"79091234567":{"status":"OK","status_code":100,
  #                          "sms_id":"123","cost":"1.49"}},
  #    "balance":...}
  #
  # Same Result interface as SmscClient — `Sms::Client.send` (provider router)
  # абстрагирует выбор.
  class SmsRuClient
    BASE_URL = 'https://sms.ru/sms/send'.freeze
    TIMEOUT = 10

    Result = Struct.new(:success?, :message_id, :cost, :raw, :error, keyword_init: true)

    class ConfigError < StandardError; end

    def self.send(phone:, message:, sender: nil)
      new.send(phone: phone, message: message, sender: sender)
    end

    def initialize
      @api_id = ENV['SMSRU_API_ID'].to_s
      @sender = ENV['SMSRU_SENDER'].to_s.presence
      return if @api_id.present? && @api_id != 'your_smsru_api_id'

      raise ConfigError, 'SMSRU_API_ID not configured'
    end

    # Phone: 79091234567 / +79091234567 / 89091234567 — SMS.ru normalize'ит сам,
    # но на всякий пропустим только цифры.
    def send(phone:, message:, sender: nil)
      digits = phone.to_s.gsub(/\D/, '')
      return Result.new(success?: false, error: "invalid phone: #{phone.inspect}") if digits.length < 10

      params = {
        api_id:    @api_id,
        to:        digits,
        msg:       message,
        json:      1,
        from:      sender || @sender
      }.compact

      uri = URI(BASE_URL)
      uri.query = URI.encode_www_form(params)
      response = perform_request(uri)
      return Result.new(success?: false, error: "HTTP #{response.code}", raw: response.body) unless response.is_a?(Net::HTTPSuccess)

      parse_response(response.body, digits)
    rescue StandardError => e
      Result.new(success?: false, error: "#{e.class}: #{e.message.truncate(160)}")
    end

    private

    def perform_request(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      http.get(uri.request_uri)
    end

    # SMS.ru status_code semantics:
    #   100 — success
    #   101+ — failure (200=no api_id, 201=balance empty, 202=bad phone, etc.)
    # См. https://sms.ru/api/codes
    def parse_response(body, digits)
      data = JSON.parse(body)
      return Result.new(success?: false, error: "API: #{data['status_text'] || data['status']}", raw: data) unless data['status_code'].to_i == 100

      per_phone = data.dig('sms', digits) || {}
      if per_phone['status_code'].to_i == 100
        Result.new(success?: true, message_id: per_phone['sms_id'], cost: per_phone['cost'].to_f, raw: data)
      else
        Result.new(success?: false, error: per_phone['status_text'] || 'per-phone error', raw: data)
      end
    rescue JSON::ParserError => e
      Result.new(success?: false, error: "JSON parse: #{e.message}", raw: body)
    end
  end
end
