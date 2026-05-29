# frozen_string_literal: true

# Webhook endpoint registered in Topnlab admin to push card events:
#   POST /webhooks/topnlab?key=<KEY>
#   body (application/x-www-form-urlencoded): id=<int>&type=realty
#
# Auth: `key` URL/body param must match ENV['TOPNLAB_WEBHOOK_KEY']
# (falls back to ENV['TOPNLAB_API_KEY']). Compared constant-time via SHA256
# digests so timing attacks can't probe the secret.
#
# We enqueue a single-property import job. Realty is the only kind we mirror;
# `order` (buyer/tenant inquiries) and `service` (custom orders) are logged
# but not yet acted upon.
module Webhooks
  class TopnlabController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false
    before_action :require_topnlab_key

    def create
      id   = params[:id].to_s
      type = params[:type].to_s

      Rails.logger.info("Webhook Topnlab: id=#{id} type=#{type}")
      return head :unprocessable_entity if id.blank?

      # Phase 4E — idempotency dedup. Topnlab может retry webhook (network blip,
      # 5xx response) — Redis SETNX EX 5min prevents double-process of same
      # (type, id) tuple. Phase 11 Iter 26 AlertThrottle pattern reuse.
      return head :ok if duplicate?(type, id)

      # Phase 4E — webhook health metric (cron WebhookHealthWatcherJob алертит
      # директорам если last_webhook_at > 24h ago — silent failure detection).
      mark_webhook_seen!

      case type
      when 'realty'
        TopnlabPropertyImportJob.perform_later(id)
      when 'order'
        # Re-sync a single BuyerOrder from CRM, затем (Phase 4E)
        # Lead::Intake.call(source: 'crm_webhook') — для NEW orders создаст
        # LeadEvent + anchor в #ДИСПЕТЧЕРСКОЙ.
        TopnlabOrdersSyncJob.perform_later
        TopnlabCrmIntakeJob.perform_later(id)
      else
        Rails.logger.info("Webhook Topnlab: type=#{type.inspect} not handled (yet)")
      end

      head :ok
    end

    private

    # Phase 4E — Redis dedup key per (type, id). TTL 5 min — handles Topnlab
    # retry storm без блокирования legit re-events позже.
    def duplicate?(type, id)
      key = "topnlab:webhook:#{type}:#{id}"
      redis = redis_conn
      return false unless redis

      ok = redis.set(key, '1', nx: true, ex: 300)
      unless ok
        Rails.logger.info("Webhook Topnlab: duplicate type=#{type} id=#{id} (dedup TTL active)")
        return true
      end
      false
    rescue StandardError => e
      Rails.logger.warn("[TopnlabController#duplicate?] redis: #{e.message}")
      false # fail-open
    end

    def mark_webhook_seen!
      redis = redis_conn
      return unless redis

      redis.set('topnlab:last_webhook_at', Time.current.iso8601, ex: 7.days.to_i)
    rescue StandardError => e
      Rails.logger.warn("[TopnlabController#mark_webhook_seen!] redis: #{e.message}")
    end

    def redis_conn
      @redis_conn ||= begin
        require 'redis' unless defined?(Redis)
        Redis.new(url: ENV.fetch('REDIS_URL', 'redis://redis:6379/0'))
      rescue StandardError
        nil
      end
    end

    def require_topnlab_key
      expected = ENV['TOPNLAB_WEBHOOK_KEY'].presence || ENV['TOPNLAB_API_KEY'].to_s
      submitted = params[:key].to_s
      if expected.blank?
        Rails.logger.warn('Webhook Topnlab: no TOPNLAB_WEBHOOK_KEY / TOPNLAB_API_KEY configured')
        head :service_unavailable and return
      end
      digest = ->(s) { ::Digest::SHA256.hexdigest(s.to_s) }
      return if ::ActiveSupport::SecurityUtils.secure_compare(digest.call(submitted), digest.call(expected))

      Rails.logger.warn("Webhook Topnlab: bad key from #{request.remote_ip}")
      head :forbidden
    end
  end
end
