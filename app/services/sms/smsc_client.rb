# frozen_string_literal: true

require 'net/http'
require 'json'

module Sms
  # SMSC.ru API client — Russian SMS gateway most agencies use.
  #
  # Docs: https://smsc.ru/api/http/
  # Endpoint: https://smsc.ru/sys/send.php
  # Auth: login + password (SMSC_LOGIN/SMSC_PASSWORD env).
  # Cost: ~2-4 ₽/SMS RU numbers.
  #
  # Returns Result(success:, message_id:, cost:, raw:, error:).
  # На production-failure (timeout, 4xx, balance=0) — Result.success?=false +
  # error. Caller отвечает за logging/retry/fallback.
  class SmscClient
    BASE_URL = 'https://smsc.ru/sys/send.php'.freeze
    TIMEOUT = 10

    Result = Struct.new(:success?, :message_id, :cost, :raw, :error, keyword_init: true)

    class ConfigError < StandardError; end

    def self.send(phone:, message:, sender: nil)
      new.send(phone: phone, message: message, sender: sender)
    end

    def initialize
      @login    = ENV['SMSC_LOGIN'].to_s
      @password = ENV['SMSC_PASSWORD'].to_s
      @sender   = ENV['SMSC_SENDER'].to_s.presence
      return if @login.present? && @password.present? && @login != 'your_smsc_login'

      raise ConfigError, 'SMSC_LOGIN/SMSC_PASSWORD not configured'
    end

    # Send одну SMS. Phone в формате +7XXXXXXXXXX или 7XXXXXXXXXX (10 digits
    # after country code). Message — UTF-8, до 70 chars/segment для Cyrillic.
    def send(phone:, message:, sender: nil)
      digits = phone.to_s.gsub(/\D/, '')
      return Result.new(success?: false, error: "invalid phone: #{phone.inspect}") if digits.length < 10

      params = {
        login:   @login,
        psw:     @password,
        phones:  digits,
        mes:     message,
        charset: 'utf-8',
        fmt:     3, # JSON response
        sender:  sender || @sender
      }.compact

      uri = URI(BASE_URL)
      uri.query = URI.encode_www_form(params)

      response = perform_request(uri)
      return Result.new(success?: false, error: "HTTP #{response.code}", raw: response.body) unless response.is_a?(Net::HTTPSuccess)

      parse_response(response.body)
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

    # SMSC JSON format:
    #   success: {"id":N, "cnt":1, "cost":"2.50", "balance":"100.00"}
    #   error:   {"error":"...", "error_code":N}
    def parse_response(body)
      data = JSON.parse(body)
      if data['error'].present?
        Result.new(success?: false, error: "SMSC: #{data['error']}", raw: data)
      else
        Result.new(success?: true, message_id: data['id'], cost: data['cost'].to_f, raw: data)
      end
    rescue JSON::ParserError => e
      Result.new(success?: false, error: "JSON parse: #{e.message}", raw: body)
    end
  end
end
