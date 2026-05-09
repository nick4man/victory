# frozen_string_literal: true

# Sync MLS-network listings from Topnlab into MlsListing.
#
# Strategy: for each (action × realty_type) combination, call get_ids with type='mls'
# (network/feed listings — distinct from agency's own type='realty'); fetch entities in
# batches of 100 via get_entities_from_mls (1s throttle). Upsert by [source, external_id].
#
# If get_ids type='mls' is unsupported by the agency's account, the loop completes with
# zero results and the rake task reports "0 imported" — valuation falls back to local
# Property records or regional averages.
module MlsSync
  class TopnlabSyncService
    REALTY_TYPES = %w[flat room house land commerce garage].freeze
    ACTIONS      = %w[sale rent].freeze
    MLS_TYPE     = 'mls'

    def initialize(client: Topnlab::Client.new, source: 'topnlab_mls')
      @client = client
      @source = source
    end

    def call
      total_ids = 0
      total_upserted = 0
      errors = []

      ACTIONS.each do |action|
        REALTY_TYPES.each do |realty_type|
          ids = fetch_ids(action: action, realty_type: realty_type)
          total_ids += ids.size
          next if ids.empty?

          payloads = fetch_entities(ids)
          payloads.each_value do |payload|
            attrs = MlsSync::ListingMapper.new(payload, source: @source).to_attributes
            next unless attrs

            upsert(attrs)
            total_upserted += 1
          end
        rescue StandardError => e
          errors << "#{action}/#{realty_type}: #{e.class} #{e.message}"
          Rails.logger.warn("[MlsSync] #{action}/#{realty_type} failed: #{e.class} #{e.message}")
        end
      end

      { success: errors.empty?, ids_seen: total_ids, upserted: total_upserted, errors: errors }
    end

    private

    def fetch_ids(action:, realty_type:)
      Array(@client.get_ids(type: MLS_TYPE, action: action, realty_type: realty_type, is_feed: true))
    rescue Topnlab::Client::Error => e
      Rails.logger.warn("[MlsSync] get_ids #{action}/#{realty_type} failed: #{e.message}")
      []
    end

    def fetch_entities(ids)
      hash = @client.get_entities_from_mls(ids)
      hash.is_a?(Hash) ? hash : {}
    end

    def upsert(attrs)
      record = MlsListing.find_or_initialize_by(
        external_source: attrs[:external_source], external_id: attrs[:external_id]
      )
      record.assign_attributes(attrs)
      record.save!
    end
  end
end
