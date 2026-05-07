# frozen_string_literal: true

class HealthController < ActionController::Base
  before_action :restrict_to_internal!, except: [:index]

  def index
    render json: { status: 'ok', timestamp: Time.current.iso8601 }
  end

  def database
    ActiveRecord::Base.connection.execute('SELECT 1')
    render json: { status: 'ok', database: 'connected' }
  rescue StandardError => e
    render json: { status: 'error', database: 'connection_failed' }, status: :service_unavailable
  end

  def redis
    render json: { status: 'skipped', message: 'Redis not configured' }
  end

  def sidekiq
    render json: { status: 'skipped', message: 'Sidekiq not enabled' }
  end

  private

  INTERNAL_CIDRS = [
    IPAddr.new('127.0.0.0/8'),
    IPAddr.new('10.0.0.0/8'),
    IPAddr.new('172.16.0.0/12'),
    IPAddr.new('192.168.0.0/16'),
    IPAddr.new('::1/128')
  ].freeze

  def restrict_to_internal!
    ip = IPAddr.new(request.remote_ip)
    return if INTERNAL_CIDRS.any? { |cidr| cidr.include?(ip) }

    render json: { error: 'Not found' }, status: :not_found
  rescue IPAddr::InvalidAddressError
    render json: { error: 'Not found' }, status: :not_found
  end
end
