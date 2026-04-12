# frozen_string_literal: true

class HealthController < ActionController::Base
  def index
    render json: { status: 'ok', timestamp: Time.current.iso8601 }
  end

  def database
    ActiveRecord::Base.connection.execute('SELECT 1')
    render json: { status: 'ok', database: 'connected' }
  rescue => e
    render json: { status: 'error', database: e.message }, status: :service_unavailable
  end

  def redis
    render json: { status: 'skipped', message: 'Redis not configured' }
  end

  def sidekiq
    render json: { status: 'skipped', message: 'Sidekiq not enabled' }
  end
end
