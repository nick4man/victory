# frozen_string_literal: true

# Translates a Topnlab `type=order` payload into BuyerOrder attributes.
# Defensive mapping: Topnlab field names are not strictly documented for orders,
# so we try several candidates per attribute and fall back to nil.
module Topnlab
  class OrderMapper
    REALTY_TYPES = %w[flat room house land commerce garage].freeze

    # Topnlab order's `object_type` is numeric. Verified empirically:
    #   1=flat. Others assumed by parallel to property realty_types.
    OBJECT_TYPE_MAP = {
      1 => 'flat', 2 => 'room', 3 => 'house',
      4 => 'land', 5 => 'commerce', 6 => 'garage'
    }.freeze

    def initialize(payload, agents_index = {})
      @p = payload || {}
      @agents = agents_index
    end

    # @return [Hash, nil] attributes for BuyerOrder.assign_attributes; nil if unusable.
    def to_attributes
      return nil unless @p['id']
      return nil if action.blank?

      addr = address_tags

      {
        crm_id:         @p['id'],
        deal_type:      action,
        realty_type:    realty_type,
        price_min:      pos_int(@p['price_from'] || @p['min_price']),
        price_max:      pos_int(@p['price_to']   || @p['max_price']),
        area_min:       pos_dec(@p['total_area_from'] || @p['area_from']),
        area_max:       pos_dec(@p['total_area_to']   || @p['area_to']),
        rooms_min:      rooms_extreme(:min),
        rooms_max:      rooms_extreme(:max),
        preferred_districts: addr[:districts],
        preferred_cities:    addr[:cities],
        metro_stations:      addr[:metros],
        description:    description,
        user_id:        agent_id,
        stage_name:     @p.dig('stage', 'name') || @p['stage_name'],
        stage_id:       pos_int(@p.dig('stage', 'id') || @p['stage_id']),
        deal_state:     @p['deal_state'].presence || 'active',
        client_name:     client_first_name,
        client_phone_masked: masked_phone,
        client_crm_id:   client_crm_id,
        fc_data:         fc_data,
        synced_at:       Time.current
      }
    end

    private

    def action
      a = @p['action'].to_s.strip.downcase
      %w[sale rent daily].include?(a) ? a : nil
    end

    def realty_type
      OBJECT_TYPE_MAP[@p['object_type'].to_i] ||
        (@p['realty_type'].to_s.strip.downcase if REALTY_TYPES.include?(@p['realty_type'].to_s.strip.downcase))
    end

    # rooms is an array of {"id" => N, "value" => "X ком."} objects representing
    # the buyer's selected room counts. id directly matches room count
    # (verified: id=3 ↔ "2 ком." actually maps to count, but counts may include studio variants).
    def rooms_extreme(side)
      raw = @p['rooms']
      return nil unless raw.is_a?(Array) && raw.any?
      ids = raw.filter_map { |item| item.is_a?(Hash) ? item['id'].to_i : nil }.reject(&:zero?)
      return nil if ids.empty?
      side == :min ? ids.min : ids.max
    end

    def address_tags
      raw = @p['address_tags']
      return { districts: [], cities: [], metros: [] } unless raw.is_a?(Array)

      cities = raw.flat_map { |t| t.is_a?(Hash) ? Array(t['city_name']) : [] }
      metros = raw.flat_map { |t| t.is_a?(Hash) ? Array(t['metro']) : [] }
      districts = raw.flat_map do |t|
        next [] unless t.is_a?(Hash)
        Array(t['folk_district_name']) + Array(t['district_name'])
      end

      {
        districts: districts.compact_blank.map(&:to_s).uniq,
        cities:    cities.compact_blank.map(&:to_s).uniq,
        metros:    metros.compact_blank.map(&:to_s).uniq
      }
    end

    def description
      raw = @p['mydescription'].presence || @p['description'].presence || @p['comment'].presence
      return nil if raw.blank?
      raw.to_s.gsub(/<\/?[^>]+>/, ' ').gsub(/\s+/, ' ').strip[0, 4900]
    end

    def agent_id
      email = (@p.dig('user', 'email') || @p['user_email']).to_s.downcase
      @agents[email] || User.find_by('LOWER(email) = ?', email)&.id
    end

    def client_crm_id
      id = @p.dig('client', 'id') || @p['client_id']
      n = id.to_i
      n.positive? ? n : nil
    end

    def client_first_name
      first = @p.dig('client', 'firstname') || @p['firstname']
      first.to_s.strip.presence
    end

    def masked_phone
      raw = (@p.dig('client', 'phone') || @p['phone'] || @p['phone_num']).to_s.gsub(/\D/, '')
      return nil if raw.length < 4
      tail = raw[-4..]
      "+7***-***-#{tail[0,2]}-#{tail[2,2]}"
    end

    def fc_data
      @p.select { |k, _| k.to_s.start_with?('fc_') }.transform_values { |v| v.is_a?(Hash) ? v.slice('name', 'value', 'type') : v }
    end

    def pos_int(v)
      n = v.to_i
      n.positive? ? n : nil
    end

    def pos_dec(v)
      f = v.to_f
      f.positive? ? f : nil
    end
  end
end
