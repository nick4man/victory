# frozen_string_literal: true

# Phase 9 Iter 9 — Async digest refresh с де-дупликацией через Redis lock.
#
# Раньше Task#after_commit вызывал DispatcherDigest.refresh_for_today!
# синхронно (~100ms на edit_message_text). При параллельных Task updates
# был race на TG edit_message_text — потенциальная потеря update.
#
# Теперь: after_commit → perform_later. Внутри job — Redis-based debounce
# чтобы 5 parallel updates → 1 actual TG edit_message_text (через 1s).
class DispatcherDigestRefreshJob
  include Sidekiq::Job
  sidekiq_options queue: :scheduled, retry: 2

  LOCK_KEY    = 'digest:dispatcher:refresh:lock'
  LOCK_TTL    = 5.seconds
  DEBOUNCE_MS = 1000

  def perform
    # Redis-lock дедупликация. Если уже идёт refresh (или recently completed) —
    # skip; следующий triggered after_commit подберёт next state.
    return :locked unless acquire_lock

    sleep(DEBOUNCE_MS / 1000.0) # debounce — собрать одновременные updates
    Telegram::WorkBot::DispatcherDigest.refresh_for_today!
    :refreshed
  ensure
    release_lock
  end

  private

  def acquire_lock
    return true unless defined?(Rails) && Rails.application

    redis = redis_connection
    return true unless redis

    redis.set(LOCK_KEY, Time.current.iso8601, ex: LOCK_TTL.to_i, nx: true)
  rescue StandardError => e
    Rails.logger.warn("[DispatcherDigestRefreshJob] lock acquire failed: #{e.message}")
    true # fallback — пропускаем lock check, лучше дубль чем потеря
  end

  def release_lock
    redis = redis_connection
    redis&.del(LOCK_KEY)
  rescue StandardError
    nil
  end

  def redis_connection
    @redis ||= begin
      url = ENV['REDIS_URL'].presence || 'redis://localhost:6379/0'
      require 'redis' unless defined?(Redis)
      Redis.new(url: url)
    rescue StandardError
      nil
    end
  end
end
