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
  #
  # Граничные:
  #   • Redis down → return true (fail-open: лучше шум чем тишина)
  #   • Concurrent first-alert (две параллельные jobs) → одна выиграет SETNX,
  #     вторая получит false — нормально для throttle.
  class AlertThrottle
    WINDOW = 5.minutes

    def self.allow?(key:)
      new(key: key).allow?
    end

    def self.suppressed_count(key:)
      new(key: key).suppressed_count
    end

    def initialize(key:)
      @key = "alert_throttle:#{key}"
      @counter_key = "#{@key}:suppressed"
    end

    # @return [Boolean] true если alert надо отправить (первый в окне),
    #                   false если в throttle window (увеличит counter).
    def allow?
      redis = connection
      return true if redis.nil? # fail-open

      # SETNX-style: установить только если ключа нет. EX=TTL в секундах.
      # SET NX EX — атомарная операция.
      ok = redis.set(@key, '1', nx: true, ex: WINDOW.to_i)
      return true if ok

      # В throttle window — increment suppressed counter, return false.
      redis.incr(@counter_key)
      redis.expire(@counter_key, WINDOW.to_i)
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
