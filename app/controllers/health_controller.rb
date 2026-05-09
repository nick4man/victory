# frozen_string_literal: true

class HealthController < ApplicationController
  skip_before_action :setup_meta_tags, raise: false

  def index
    render json: { status: 'ok', timestamp: Time.current.iso8601 }
  end

  def database
    ActiveRecord::Base.connection.execute('SELECT 1')
    render json: { status: 'ok', component: 'database' }
  rescue StandardError => e
    render json: { status: 'error', component: 'database', error: e.message }, status: :service_unavailable
  end

  def redis
    Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')).ping
    render json: { status: 'ok', component: 'redis' }
  rescue StandardError => e
    render json: { status: 'error', component: 'redis', error: e.message }, status: :service_unavailable
  end

  def sidekiq
    stats = Sidekiq::Stats.new
    render json: {
      status: 'ok',
      component: 'sidekiq',
      processed: stats.processed,
      failed: stats.failed,
      enqueued: stats.enqueued
    }
  rescue StandardError => e
    render json: { status: 'error', component: 'sidekiq', error: e.message }, status: :service_unavailable
  end
end
