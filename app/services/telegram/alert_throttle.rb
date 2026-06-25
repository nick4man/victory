# frozen_string_literal: true

module Telegram
  # Phase 11 Iter 26 — Redis-based throttle для critical-job DM alerts.
  #
  # Зачем: до этого фикса при transient failure (Sidekiq retry × 3 на каждый
  # экземпляр + 5 параллельных workers) directors могли получить десятки
  # одинаковых alerts за минуту → alert fatigue → реальные проблемы игнорятся.
  #
  # Fix: 5-min bucket per (job_class + exception_class). Первый alert в окне
  # проходит, последующие — silently dropped + Rails.logger.info с counter.
  # При истечении окна — следующий alert содержит «(suppressed X over 5min)».
  #
  # Контракт:
  #   Telegram::AlertThrottle.allow?(key: 'MyJob:RuntimeError') → bool
  #   Telegram::AlertThrottle.allow?(key: 'anomaly:7:overdue:2026-05-29', ttl: 24.hours)
  #
  # Phase 16.7 — optional `ttl:` kwarg. Default = WINDOW (5min, для legacy
  # storm-protection). Custom ttl (24.hours) для pro-active anomaly alerts —
  # per-staff-per-metric-per-day discipline. Backward-compatible.
  #
  # Граничные:
  #   • Redis down → return true (fail-open: лучше шум чем тишина)
  #   • Concurrent first-alert (две параллельные jobs) → одна выиграет SETNX,
  #     вторая получит false — нормально для throttle.
  class AlertThrottle
    WINDOW = 5.minutes

    def self.allow?(key:, ttl: WINDOW)
      new(key: key, ttl: ttl).allow?
    end

    def self.suppressed_count(key:)
      new(key: key).suppressed_count
    end

    # Phase 13 Iter 48 — aggregate всех suppressed counters в текущем окне.
    # Используется /admin/health.json чтобы surface'ить throttled alerts
    # operator'у (raw counters else invisible).
    #
    # Redis SCAN по pattern 'alert_throttle:*:suppressed' — non-blocking,
    # safe для production. Cap at 50 keys как defensive limit (не должно
    # быть >50 distinct throttle keys одновременно).
    #
    # @return [Hash{String => Integer}] {throttle_key (без префикса) => count}
    def self.all_suppressed_summary
      redis = new(key: 'dummy').send(:connection)
      return {} if redis.nil?

      result = {}
      cursor = '0'
      iterations = 0
      loop do
        cursor, keys = redis.scan(cursor, match: 'alert_throttle:*:suppressed', count: 100)
        keys.each do |k|
          throttle_key = k.delete_prefix('alert_throttle:').delete_suffix(':suppressed')
          result[throttle_key] = redis.get(k).to_i
          break if result.size >= 50
        end
        break if cursor == '0' || result.size >= 50 || (iterations += 1) > 10
      end
      result
    rescue StandardError => e
      Rails.logger.warn("[AlertThrottle.all_suppressed_summary] #{e.message}")
      {}
    end

    def initialize(key:, ttl: WINDOW)
      @key = "alert_throttle:#{key}"
      @counter_key = "#{@key}:suppressed"
      @ttl = ttl
    end

    # @return [Boolean] true если alert надо отправить (первый в окне),
    #                   false если в throttle window (увеличит counter).
    def allow?
      redis = connection
      return true if redis.nil? # fail-open

      # SETNX-style: установить только если ключа нет. EX=TTL в секундах.
      # SET NX EX — атомарная операция.
      ok = redis.set(@key, '1', nx: true, ex: @ttl.to_i)
      return true if ok

      # В throttle window — increment suppressed counter, return false.
      redis.incr(@counter_key)
      redis.expire(@counter_key, @ttl.to_i)
      false
    rescue StandardError => e
      Rails.logger.warn("[AlertThrottle] redis error: #{e.message}")
      true # fail-open
    end

    # Сколько alert'ов было подавлено в текущем окне.
    # Полезно для следующего allow?-pass — добавить в текст «(suppressed N)».
    def suppressed_count
      redis = connection
      return 0 if redis.nil?

      redis.get(@counter_key).to_i
    rescue StandardError
      0
    end

    private

    def connection
      @connection ||= begin
        url = ENV['REDIS_URL'].presence || 'redis://localhost:6379/0'
        require 'redis' unless defined?(Redis)
        Redis.new(url: url)
      rescue StandardError
        nil
      end
    end
  end
end
