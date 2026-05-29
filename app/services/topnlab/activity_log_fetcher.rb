# frozen_string_literal: true

module Topnlab
  # Fetches change-history events for a Topnlab entity via /get-entities-logs
  # and renders user-friendly Russian labels. Cached 5 min in Rails.cache to keep
  # the dashboard show pages snappy and stay under Topnlab's 1 req/s limit.
  class ActivityLogFetcher
    LOGS_CACHE_TTL   = 5.minutes
    LABELS_CACHE_TTL = 24.hours

    def initialize(client: Topnlab::Client.new)
      @client = client
    end

    # @return [Array<Hash>] {at:, event_type:, label:, data:, user_id:, user:}
    def fetch(crm_id, limit: 30)
      return [] if crm_id.blank?

      cache_key = "topnlab:logs:#{crm_id}:#{limit}"
      Rails.cache.fetch(cache_key, expires_in: LOGS_CACHE_TTL) do
        raw = @client.get_entities_logs([crm_id])
        labels = event_type_labels
        Array(raw).first(limit).map { |log| presentable(log, labels) }.compact
      end
    rescue Topnlab::Client::Error => e
      Rails.logger.warn("[ActivityLog] fetch failed for ##{crm_id}: #{e.message}")
      []
    end

    # Topnlab has 400+ event_type codes; cache the registry for a day.
    def event_type_labels
      Rails.cache.fetch('topnlab:event_type_labels', expires_in: LABELS_CACHE_TTL) do
        raw = @client.get_event_types
        raw.is_a?(Hash) ? raw.transform_keys(&:to_i) : {}
      rescue Topnlab::Client::Error => e
        Rails.logger.warn("[ActivityLog] event_types fetch failed: #{e.message}")
        {}
      end
    end

    private

    def presentable(log, labels)
      return nil unless log.is_a?(Hash)

      at = parse_time(log['created_at'])
      type_code = log['event_type'].to_i
      raw_label = labels[type_code]
      label = raw_label.is_a?(String) ? interpolate(raw_label, log['data']) : "Событие ##{type_code}"
      {
        at:         at,
        event_type: type_code,
        label:      label,
        data:       log['data'],
        user_id:    log['user_id'],
        user:       resolve_user(log['user_id']),
        id:         log['id']
      }
    end

    # Topnlab labels can have :count placeholders, e.g. "Добавлено :count фотографий".
    def interpolate(label, data)
      return label unless label.include?(':') && data.is_a?(Hash)
      label.gsub(/:(\w+)/) { |m| data[Regexp.last_match(1)].to_s.presence || m }
    end

    def parse_time(raw)
      return nil if raw.blank?
      Time.zone.parse(raw.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Cached lookup so we don't hit DB once per log row.
    def resolve_user(crm_user_id)
      return nil if crm_user_id.blank?
      @user_cache ||= {}
      @user_cache[crm_user_id] ||= User.find_by(crm_user_id: crm_user_id)
    end
  end
end
