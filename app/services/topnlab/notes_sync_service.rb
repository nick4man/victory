# frozen_string_literal: true

module Topnlab
  class NotesSyncService
    def initialize(client: Topnlab::Client.new)
      @client = client
    end

    # Pull all CRM notes for one entity into local Note table (idempotent).
    # @param notable [Property|BuyerOrder|Inquiry|ServiceOrder]
    # @param crm_id [Integer]
    # @param type [String] 'realty' | 'order' | 'service'
    # @return [Integer] notes inserted
    def pull(notable, crm_id:, type:)
      payload = @client.get_notes(id: crm_id, type: type)
      data = unwrap(payload)
      inserted = 0
      Array(data).each do |n|
        next unless n.is_a?(Hash) && n['id']

        note = Note.find_or_initialize_by(crm_note_id: n['id'])
        next unless note.new_record?

        note.assign_attributes(
          notable:        notable,
          crm_user_id:    n['user_id'],
          note:           n['note'].to_s,
          sync_state:     'synced',
          synced_at:      Time.current,
          crm_entity_type: type
        )
        if (created_at = parse_time(n['created_at']))
          note.created_at = created_at
        end
        note.save!
        inserted += 1
      end
      inserted
    rescue Topnlab::Client::Error => e
      Rails.logger.warn("[NotesSync] pull failed for #{type} ##{crm_id}: #{e.message}")
      0
    end

    # Push a locally-created Note up to CRM via /set-note.
    # @param note [Note] must have crm_entity_type and notable.crm_id resolvable.
    # @return [Boolean] true on success
    def push(note)
      crm_id = resolve_crm_id(note.notable)
      type   = note.crm_entity_type.presence || derive_type(note.notable)
      return note.update(sync_state: 'failed') if crm_id.blank? || type.blank?

      result = @client.set_note(
        id:      crm_id,
        type:    type,
        note:    note.note,
        user_id: note.user&.crm_user_id || ENV['TOPNLAB_FALLBACK_USER_ID'].to_i
      )
      if result.is_a?(Hash) && %w[ok success].include?(result['status'])
        note.update(sync_state: 'synced', synced_at: Time.current, crm_entity_type: type)
        true
      else
        Rails.logger.warn("[NotesSync] push for note #{note.id} returned: #{result.inspect}")
        note.update(sync_state: 'failed')
        false
      end
    rescue Topnlab::Client::Error => e
      Rails.logger.warn("[NotesSync] push failed for note #{note.id}: #{e.message}")
      note.update(sync_state: 'failed')
      false
    end

    private

    # Topnlab inconsistently double-wraps in 'data' (same as getStructure).
    def unwrap(payload)
      return [] unless payload.is_a?(Hash)
      data = payload['data']
      return data if data.is_a?(Array)
      return data['data'] if data.is_a?(Hash) && data['data'].is_a?(Array)
      []
    end

    def resolve_crm_id(notable)
      return notable.crm_id if notable.respond_to?(:crm_id) && notable.crm_id.present?
      return notable.external_id if notable.respond_to?(:external_id) && notable.external_id.to_s.match?(/^\d+$/)
      nil
    end

    def derive_type(notable)
      case notable
      when Property      then 'realty'
      when BuyerOrder    then 'order'
      when ServiceOrder  then 'service'
      end
    end

    def parse_time(raw)
      return nil if raw.blank?
      Time.zone.parse(raw.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
