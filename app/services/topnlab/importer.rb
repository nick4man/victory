# frozen_string_literal: true

require 'set'

# Pulls properties from Topnlab CRM into our Property model.
# Default filter: deal_state ∈ ['ad','active','lead','prepayment','deferred']
# i.e. all "alive" stages (excludes archive/denied/deal). This matches what an
# agent thinks of as "объекты в работе и в рекламе". Switch to {in_ad: true}
# only if you need the narrower "currently rotating" subset.
#
# Usage:
#   Topnlab::Importer.new.call                              # default broad filter
#   Topnlab::Importer.new(filter: { in_ad: true }).call     # narrow: only currently advertised
#   Topnlab::Importer.new(filter: {}).call                  # fetch every card (incl. archive)
module Topnlab
  class Importer
    REALTY_TYPES    = %w[flat room house land commerce garage].freeze
    ACTIONS         = %w[sale rent].freeze
    ACTIVE_STATES   = %w[ad active lead prepayment deferred].freeze
    COMPLETED_STATES = %w[deal].freeze

    # In completed-mode (deal_states: COMPLETED_STATES) we ask Topnlab to
    # `append=deals` so payloads include closure date and final amount.
    # Live-mode keeps the existing `append=stages` behaviour.
    def initialize(client: Topnlab::Client.new, filter: { deal_state: ACTIVE_STATES }, mode: nil)
      @client = client
      @filter = filter
      @mode   = mode || infer_mode
    end

    def call
      # Wrap the entire sweep in a TopnlabSyncRun row so the admin status
      # page can show "last sync 5 min ago, ingested 99, archived 84"
      # without mining logs. Track is idempotent re-entry-safe — if the
      # model doesn't exist yet (migration not run), it no-ops gracefully.
      sync_run = (TopnlabSyncRun.start rescue nil)
      result = call_inner
      errors = []
      errors << "#{result[:failed]} upsert failed" if result[:failed].to_i.positive?
      errors << "#{result[:fetch_errors]} fetch error(s) — sweep incomplete, archive skipped" if result[:fetch_errors].to_i.positive?
      sync_run&.finish!(
        ids_seen:       result[:imported].to_i + result[:skipped].to_i + result[:failed].to_i,
        upserted:       result[:imported].to_i,
        archived:       result[:archived].to_i,
        photos_pending: 0,
        errors:         errors
      )
      result
    rescue StandardError => e
      sync_run&.update(
        finished_at: Time.current, status: 'failed',
        errors: "#{e.class}: #{e.message.to_s.truncate(500)}"
      )
      raise
    end

    def call_inner
      agents_index = build_agents_index
      type_index   = PropertyType.where(slug: REALTY_TYPES).index_by(&:slug)
      fallback     = User.find_by(email: ENV.fetch('TOPNLAB_FALLBACK_USER_EMAIL', 'topnlab@viktory-realty.ru'))

      seen_ids     = Set.new
      imported     = 0
      skipped      = 0
      failed       = 0
      fetch_errors = 0

      ACTIONS.each do |action|
        REALTY_TYPES.each do |realty_type|
          begin
            ids = @client.get_ids(type: 'realty', action: action, realty_type: realty_type, **@filter)
            Rails.logger.info("Topnlab: action=#{action} type=#{realty_type} → #{ids.size} ids")
            next if ids.empty?

            ids.each_slice(300) do |chunk|
              entities = @client.get_entities(chunk, type: 'realty', append: append_param)
              entities.each_value do |payload|
                result = upsert_one(payload, agents_index, type_index, fallback&.id)
                case result
                when :imported then imported += 1
                when :skipped  then skipped += 1
                when :failed   then failed += 1
                end
                seen_ids << payload['id'] if payload.is_a?(Hash) && payload['id']
              end
            end
          rescue StandardError => e
            # A fetch-stage failure (network/auth/timeout) means this sweep
            # segment returned NOTHING — seen_ids is now incomplete. Track this
            # separately from upsert `failed`, because archive_missing below must
            # NOT run on an incomplete sweep (see guard).
            Rails.logger.error("Topnlab: action=#{action} type=#{realty_type} failed: #{e.class}: #{e.message}")
            fetch_errors += 1
          end
        end
      end

      # archive_missing retires every active Property whose id is absent from
      # seen_ids — which is only safe when the sweep was COMPLETE. If any segment
      # failed to fetch (e.g. a transient network blip), seen_ids is partial and
      # archiving would falsely retire still-live listings. A single failed sweep
      # once archived the ENTIRE catalogue this way; never archive on an
      # incomplete sweep. Completed-mode is additive and never archives either.
      archived =
        if completed_mode?
          0
        elsif fetch_errors.positive?
          Rails.logger.warn("Topnlab: #{fetch_errors} fetch error(s) — sweep incomplete, skipping archive_missing to avoid false archival")
          0
        else
          archive_missing(seen_ids)
        end

      summary = { success: fetch_errors.zero?, imported: imported, skipped: skipped,
                  failed: failed, fetch_errors: fetch_errors, archived: archived }
      Rails.logger.info("Topnlab importer summary: #{summary}")
      summary
    end

    # Used by webhook / single-import path. Fetches one entity by id and upserts.
    def import_one(topnlab_id)
      payload = @client.get_entities([topnlab_id], type: 'realty').values.first
      return { success: false, error: "not_found" } if payload.nil?
      import_payload(payload)
    end

    def import_payload(payload)
      agents_index = build_agents_index
      type_index   = PropertyType.where(slug: REALTY_TYPES).index_by(&:slug)
      fallback     = User.find_by(email: ENV.fetch('TOPNLAB_FALLBACK_USER_EMAIL', 'topnlab@viktory-realty.ru'))
      result = upsert_one(payload, agents_index, type_index, fallback&.id)
      { success: result == :imported, status: result }
    end

    private

    def append_param
      completed_mode? ? 'deals' : 'stages'
    end

    def completed_mode?
      @mode == :completed
    end

    def infer_mode
      states = Array(@filter && @filter[:deal_state])
      return :completed if states.any? && (states - COMPLETED_STATES).empty?

      :live
    end

    def upsert_one(payload, agents_index, type_index, fallback_id)
      mapper = Topnlab::PropertyMapper.new(payload, agents_index, type_index, fallback_user_id: fallback_id)
      attrs  = mapper.to_attributes
      return :skipped if attrs.nil?
      return :skipped if attrs[:user_id].nil?  # safety: NOT NULL constraint

      property = Property.unscoped.find_or_initialize_by(external_source: 'topnlab', external_id: attrs[:external_id])
      property.assign_attributes(attrs)
      property.deleted_at = nil

      # Save without strict validations — Property has many "nice to have" validates that
      # CRM payloads can't always satisfy (length min, owners_count, etc.).
      if property.save(validate: false)
        # Single source of truth for publication: same gate runs for the
        # webhook path (`import_one`) AND the cron bulk sync (`#call`). Without
        # this call, the mapper used to hardcode status=:active and we'd never
        # archive properties that CRM had moved off the «ad» stage.
        property.publish_if_ready!
        urls = mapper.photo_urls
        TopnlabPhotoSyncJob.perform_later(property.id, urls) if urls.any?
        :imported
      else
        Rails.logger.warn("Topnlab upsert failed for #{attrs[:external_id]}: #{property.errors.full_messages}")
        :failed
      end
    rescue StandardError => e
      Rails.logger.error("Topnlab upsert exception for id=#{payload['id']}: #{e.class}: #{e.message}")
      :failed
    end

    def archive_missing(seen_ids)
      ids = seen_ids.to_a.map(&:to_s)
      scope = Property.unscoped.where(external_source: 'topnlab')
      scope = scope.where.not(external_id: ids) if ids.any?
      scope.where(status: Property.statuses[:active]).update_all(
        status: Property.statuses[:archived],
        published_at: nil,
        synced_at: Time.current
      )
    end

    # email (lowercase) => User.id
    def build_agents_index
      idx = {}
      User.where.not(email: nil).pluck(:id, :email).each do |id, email|
        idx[email.to_s.downcase] = id
      end
      idx
    end
  end
end
