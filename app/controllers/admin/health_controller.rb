# frozen_string_literal: true

module Admin
  # Phase 11 Iter 30 — `/admin/health` JSON endpoint для operational visibility.
  #
  # Зачем: до этого фикса для понимания «жив ли work_bot» / «не отвалился ли
  # Sidekiq» / «есть ли expired TaskBatch» / «директор зарегистрирован?»
  # требовался ssh + rails console. Это блокирует remote/oncall debugging.
  #
  # Endpoint возвращает JSON со срезом state'а:
  #   • Database connectivity
  #   • Redis connectivity (для AlertThrottle, sidekiq-cron)
  #   • Sidekiq queues + last enqueue time
  #   • TG-bot identity (есть ли directors active, managers count)
  #   • Phase 7+ counters (pending TaskBatch, open Task overdue,
  #     pending crm_sync_failed leads)
  #   • Recent error indicator (Rails.logger.error за 5 min)
  #
  # Auth: AdminTokenAuth — `/admin/health?token=...` либо cookie-session.
  # Не expose без auth (counters могут leak agency-state).
  #
  # Response shape:
  #   {
  #     "status": "ok" | "degraded" | "failed",
  #     "timestamp": "2026-05-18T14:30:00+03:00",
  #     "checks": { "db": true, "redis": true, "sidekiq": true },
  #     "bot": { "directors_active": 1, "managers_active": 3, "assignable": 5 },
  #     "operational": { "task_batches_pending": 2, "tasks_overdue": 7, "crm_sync_failed": 0 }
  #   }
  class HealthController < ApplicationController
    include AdminTokenAuth

    # Phase 12 Iter 37 — JSON 401 на auth fail вместо HTML 302 redirect.
    # AdminTokenAuth#require_admin_access по умолчанию redirect_to new_user_session_path,
    # что monitoring/curl-клиентам приходит как 302 + Location header — они не
    # понимают что это auth fail. Для JSON health endpoint должны вернуть 401 JSON.
    skip_before_action :require_admin_access
    before_action :require_admin_or_json_401

    def show
      checks      = run_checks
      bot         = bot_state
      operational = operational_counters

      status = derive_status(checks, operational)

      payload = {
        status: status,
        timestamp: Time.current.iso8601,
        checks: checks,
        bot: bot,
        operational: operational
      }

      render json: payload, status: status == 'failed' ? :service_unavailable : :ok
    end

    private

    # Phase 12 Iter 37 — auth gate подходящий monitoring-клиентам.
    # Если token/cookie ОК — пропускаем; иначе 401 JSON со внятным error.
    def require_admin_or_json_401
      return if admin_authenticated?

      render json: {
        status: 'unauthorized',
        error: 'admin token required — pass ?token=... or login via /admin/login'
      }, status: :unauthorized
    end

    def run_checks
      {
        db: db_ok?,
        redis: redis_ok?,
        sidekiq: sidekiq_ok?,
        # Phase 13 Iter 50 — Topnlab API reachability (cached 60s в Redis).
        # Operator при «все assigns зависают» сразу видит — это outage CRM
        # или local bug. Без cache health endpoint hammered'ится monitoring
        # каждые 30s — не дёргать external API дважды в минуту.
        topnlab: topnlab_ok?
      }
    end

    def db_ok?
      ActiveRecord::Base.connection.execute('SELECT 1').to_a
      true
    rescue StandardError => e
      Rails.logger.warn("[Admin::Health] db check: #{e.message}")
      false
    end

    def redis_ok?
      require 'redis' unless defined?(Redis)
      url = ENV['REDIS_URL'].presence || 'redis://localhost:6379/0'
      Redis.new(url: url, timeout: 1).ping == 'PONG'
    rescue StandardError => e
      Rails.logger.warn("[Admin::Health] redis check: #{e.message}")
      false
    end

    def sidekiq_ok?
      return false unless defined?(Sidekiq)

      require 'sidekiq/api'
      stats = Sidekiq::Stats.new
      # Sidekiq «жив» если есть processes (active workers).
      Sidekiq::ProcessSet.new.size.positive? || stats.processed.positive?
    rescue StandardError => e
      Rails.logger.warn("[Admin::Health] sidekiq check: #{e.message}")
      false
    end

    # Phase 13 Iter 50 — light Topnlab reachability check.
    # Cache result в Rails.cache (Redis) на 60s чтобы не дёргать external
    # API на каждый /admin/health hit (monitoring polling каждые 30s).
    # Timeout 2s — health endpoint должен отвечать быстро.
    def topnlab_ok?
      Rails.cache.fetch('health:topnlab_ok', expires_in: 60.seconds) do
        Timeout.timeout(2) do
          # get_users — самый дешёвый идемпотентный endpoint в нашем
          # Topnlab::Client, который мы уже используем в /link / KPI / cascade.
          Topnlab::Client.new.get_users.is_a?(Array)
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[Admin::Health] topnlab check: #{e.class}: #{e.message.to_s.truncate(120)}")
      false
    end

    def bot_state
      {
        directors_active: TelegramUser.directors.where(status: 'active').count,
        managers_active: TelegramUser.managers.where(status: 'active').count,
        assignable: TelegramUser.assignable.count
      }
    rescue StandardError => e
      Rails.logger.warn("[Admin::Health] bot_state: #{e.message}")
      { error: e.message }
    end

    def operational_counters
      {
        task_batches_pending: TaskBatch.pending.count,
        task_batches_expired_recent: TaskBatch.where(status: 'expired')
                                              .where(expired_at: 24.hours.ago..).count,
        tasks_overdue: ::Task.status_open.where(due_at: ...Time.current).count,
        crm_sync_failed: LeadEvent.where(crm_sync_failed: true).count,
        # Phase 12 Iter 38 — surface YAML/DB drift в health JSON
        topic_registry_orphans: Telegram::TopicRegistry.orphan_anchor_keys,
        topic_registry_missing: Telegram::TopicRegistry.missing_keys,
        # Phase 13 Iter 48 — surface throttled alerts (Iter 26 counters).
        # До этого фикса throttled alerts были invisible — operator видел
        # 'все ок' в health, но реальные alerts dropped'ись Redis-throttle.
        alerts_suppressed_5min: Telegram::AlertThrottle.all_suppressed_summary
      }
    rescue StandardError => e
      Rails.logger.warn("[Admin::Health] operational: #{e.message}")
      { error: e.message }
    end

    def derive_status(checks, operational)
      return 'failed' unless checks[:db]
      return 'degraded' if checks.values.any? { |v| v == false }

      # Soft-degradation signals (operational thresholds)
      return 'degraded' if operational.is_a?(Hash) &&
                          (operational[:bot_state].is_a?(Hash) && operational[:bot_state][:directors_active].to_i.zero?)

      # Phase 13 Iter 48 — >20 throttled alerts в окне → degraded
      # (operator должен расследовать рост error rate в jobs).
      if operational.is_a?(Hash) && operational[:alerts_suppressed_5min].is_a?(Hash)
        total_suppressed = operational[:alerts_suppressed_5min].values.sum
        return 'degraded' if total_suppressed > 20
      end

      'ok'
    end
  end
end
