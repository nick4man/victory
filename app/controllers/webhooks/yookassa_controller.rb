# frozen_string_literal: true

class Webhooks::YookassaController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_yookassa_ip

  def create
    # TODO: реализовать обработку событий оплаты
    render plain: 'OK'
  end

  private

  # YooKassa отправляет запросы только с определённых IP.
  # Список: https://yookassa.ru/developers/using-api/webhooks
  YOOKASSA_IPS = %w[
    185.71.76.0/27
    185.71.77.0/27
    77.75.153.0/25
    77.75.156.11
    77.75.156.35
    77.75.154.128/25
    2a02:5180::/32
  ].freeze

  def verify_yookassa_ip
    client_ip = request.remote_ip
    allowed   = YOOKASSA_IPS.any? do |cidr|
      IPAddr.new(cidr).include?(IPAddr.new(client_ip))
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      false
    end

    unless allowed
      Rails.logger.warn "[YooKassa webhook] Rejected request from IP: #{client_ip}"
      render plain: 'Forbidden', status: :forbidden
    end
  end
end
