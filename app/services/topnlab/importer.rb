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
    REALTY_TYPES = %w[flat room house land commerce garage].freeze
    ACTIONS      = %w[sale rent].freeze
    ACTIVE_STATES = %w[ad active lead prepayment deferred].freeze

    def initialize(client: Topnlab::Client.new, filter: { deal_state: ACTIVE_STATES })
      @client = client
      @filter = filter
    end

    def call
      agents_index = build_agents_index
      type_index   = PropertyType.where(slug: REALTY_TYPES).index_by(&:slug)
      fallback     = User.find_by(email: ENV.fetch('TOPNLAB_FALLBACK_USER_EMAIL', 'topnlab@viktory-realty.ru'))

      seen_ids   = Set.new
      imported   = 0
      skipped    = 0
      failed     = 0

      ACTIONS.each do |action|
        REALTY_TYPES.each do |realty_type|
          begin
            ids = @client.get_ids(type: 'realty', action: action, realty_type: realty_type, **@filter)
            Rails.logger.info("Topnlab: action=#{action} type=#{realty_type} → #{ids.size} ids")
            next if ids.empty?

            ids.each_slice(300) do |chunk|
              entities = @client.get_entities(chunk, type: 'realty')
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
            Rails.logger.error("Topnlab: action=#{action} type=#{realty_type} failed: #{e.class}: #{e.message}")
            failed += 1
          end
        end
      end

      archived = archive_missing(seen_ids)

      summary = { success: true, imported: imported, skipped: skipped, failed: failed, archived: archived }
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
