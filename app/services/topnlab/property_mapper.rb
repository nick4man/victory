# frozen_string_literal: true

require 'cgi'

# Translates a Topnlab `realty` payload into Property attributes.
# Defensive: handles missing/null values, builds address/title from parts.
module Topnlab
  class PropertyMapper
    REALTY_TYPE_TO_SLUG = {
      'flat' => 'flat', 'room' => 'room', 'house' => 'house',
      'land' => 'land', 'commerce' => 'commerce', 'garage' => 'garage'
    }.freeze

    DEAL_TYPE_MAP = { 'sale' => :sale, 'rent' => :rent, 'daily' => :daily }.freeze

    CONDITION_MAP = {
      # Topnlab values may vary — best-effort mapping
      'norepair'  => :needs_repair, 'no_repair'  => :needs_repair, 'rough'  => :needs_repair,
      'cosmetic'  => :normal,       'standard'   => :normal,       'normal' => :normal,
      'good'      => :renovated,    'renovated'  => :renovated,
      'euro'      => :euro,         'european'   => :euro,
      'designer'  => :designer,     'design'     => :designer
    }.freeze

    # Topnlab area_type codes (from /realty/getoptions → area_type):
    #   1 = м²,  2 = Сотки,  3 = Гектары
    AREA_UNIT_TO_M2 = { 1 => 1.0, 2 => 100.0, 3 => 10_000.0 }.freeze

    def initialize(payload, agents_index = {}, type_index = {}, fallback_user_id: nil)
      @p = payload || {}
      @agents = agents_index
      @types = type_index
      @fallback_user_id = fallback_user_id
    end

    # @return [Hash, nil] attributes for Property.assign_attributes; nil if payload unusable.
    def to_attributes
      return nil unless @p['id']

      area = derive_area
      attrs = {
        external_source: 'topnlab',
        external_id:     @p['id'].to_s,
        title:           build_title,
        description:     build_description,
        address:         build_address,
        district:        @p['folk_district_name'].presence || @p['district_name'],
        metro_station:   @p['metro'],
        latitude:        @p['latitude'],
        longitude:       @p['longitude'],
        price:           @p['price'].to_f.positive? ? @p['price'].to_f : 0,
        price_per_sqm:   derive_price_per_sqm,
        area:            area,
        land_area_m2:    derive_land_area_m2,
        living_area:     positive(@p['living_area']),
        kitchen_area:    positive(@p['kitchen_area']),
        rooms:           sane_rooms,
        floor:           positive_int(@p['floor']),
        total_floors:    positive_int(@p['floors'] || @p['total_floors'] || @p['floors_count']),
        building_year:   positive_int(@p['build_year'] || @p['building_year']),
        building_type:   @p['wall_material'].presence,
        condition:       map_condition,
        deal_type:       DEAL_TYPE_MAP[(@p['action'] || '').to_s] || :sale,
        has_balcony:     bool(@p['balcony'] || @p['has_balcony']),
        has_loggia:      to_int(@p['loggia_amount']).to_i.positive?,
        has_parking:     to_int(@p['parking']).to_i.positive?,
        has_elevator:    bool(@p['elevator'] || @p['has_elevator']),
        has_concierge:   bool(@p['concierge']),
        has_security:    bool(@p['security']),
        mortgage_allowed: bool_default(@p['mortgage'], true),
        ownership_type:  @p['legal_status'].presence || @p['sale_type'].presence,
        is_featured:     bool(@p['is_first_sale']),
        property_type_id: @types[(@p['realty_type'] || '').to_s]&.id,
        user_id:         resolve_user_id,
        status:          :active,
        deal_state:      @p['deal_state'].presence,
        published_at:    Time.current,
        synced_at:       Time.current
      }

      # Property has NOT NULL constraints on title/price/address; area is now nullable
      # (objects without a real area get filtered from advertising scope, better than fake "1 м²").
      attrs[:title]   = "Объект #{@p['id']}"            if attrs[:title].blank?  || attrs[:title].length < 10
      attrs[:address] = attrs[:title]                    if attrs[:address].blank?
      attrs[:description] = "Объект из CRM Topnlab"      if attrs[:description].blank?
      attrs
    end

    # @return [Array<String>] photo URLs (large preferred)
    def photo_urls
      photos = @p['photos']
      return [] unless photos.is_a?(Array)
      photos.filter_map do |ph|
        next unless ph.is_a?(Hash)
        next if ph['is_plan'] == true || ph['is_map'] == true
        next if ph['status'].to_s == 'deleted'
        ph['large_hash'].presence || ph['medium_hash'].presence || ph['small_hash'].presence
      end.compact.uniq
    end

    private

    # Returns area in м². For land we use area_land + area_land_type unit code;
    # other types use area_common (with fallback to legacy `area` key).
    # Never derives land area from price/ppm — for land that would be wrong units.
    def derive_area
      type = @p['realty_type'].to_s
      case type
      when 'land'
        raw  = @p['area_land']
        unit = AREA_UNIT_TO_M2[@p['area_land_type'].to_i] || 100.0  # default → сотки (наиболее частый ввод агентов)
        return (raw.to_f * unit).round(2) if raw.present? && raw.to_f.positive?
        nil
      else  # flat, room, house, commerce, garage
        a = (@p['area_common'].presence || @p['area']).to_f
        return a.round(2) if a.positive?
        # Fallback: price / price_per_meter (только для не-land)
        price = @p['price'].to_f
        ppm   = @p['price_per_meter'].to_f
        return (price / ppm).round(1) if price.positive? && ppm.positive?
        nil
      end
    end

    # For house with a separate plot — store the plot's area (m²) alongside the
    # house area. Used for "Дом 120 м² на участке 8 соток" presentation.
    def derive_land_area_m2
      return nil unless @p['realty_type'].to_s == 'house'
      raw = @p['area_land']
      return nil if raw.blank? || raw.to_f.zero?
      unit = AREA_UNIT_TO_M2[@p['area_land_type'].to_i] || 100.0
      (raw.to_f * unit).round(2)
    end

    # Topnlab returns `price_per_meter` literally as ₽/м² for buildings,
    # but for land it's actually ₽/сотка. We canonicalise everything to ₽/м²
    # in DB; presentation layer formats land as ₽/сотка via display helper.
    def derive_price_per_sqm
      return nil if @p['price_per_meter'].blank?
      ppm = @p['price_per_meter'].to_f
      return nil unless ppm.positive?
      if @p['realty_type'].to_s == 'land'
        (ppm / 100.0).round(2)  # ₽/сотка → ₽/м²
      else
        ppm.round(2)
      end
    end

    def sane_rooms
      r = @p['rooms']
      # Topnlab sometimes returns an enum-like code (e.g. 20 for "studio");
      # accept only plausible 1..20 actual room counts; map studio (>10) to 1.
      n = to_int(r)
      return nil if n.nil?
      return 1   if n > 9
      n
    end

    def map_condition
      raw = (@p['repair'] || @p['condition'] || @p['repair_type']).to_s.downcase.strip
      CONDITION_MAP[raw] || :normal
    end

    # Build human-readable title. Falls back through several layers
    # (rooms/area/district/city/region/street) before giving up.
    def build_title
      rooms_label = rooms_title_part
      area_value  = derive_area
      district    = @p['folk_district_name'].presence || @p['district_name'].presence
      city        = @p['city_name'].presence || @p['region_name'].presence
      street      = build_street_phrase

      # Lead with realty type; e.g. "1-комн. квартира" or just "Студия"
      head = if rooms_label == 'Студия'
               'Студия'
             else
               [rooms_label, pretty_realty_type].compact_blank.join(' ').presence || pretty_realty_type
             end
      head = head[0].mb_chars.upcase.to_s + head[1..].to_s if head.present?

      detail_parts = []
      detail_parts << area_phrase(area_value) if area_value && area_value.positive?

      location = [city, district].compact_blank.uniq.join(', ')
      location = street if location.blank? && street.present?

      [head, detail_parts.join(', ').presence, location.presence].compact_blank.join(', ')
    end

    # Human area phrase for the title — сотки for land, м² for buildings.
    # House with a separate plot adds "на N соток".
    def area_phrase(area_m2)
      type = @p['realty_type'].to_s
      if type == 'land'
        sotki = (area_m2.to_f / 100.0)
        sotki >= 1 ? "#{format_area(sotki)} соток" : "#{format_area(area_m2)} м²"
      elsif type == 'house' && (lp = derive_land_area_m2).present? && lp.positive?
        "#{format_area(area_m2)} м² на #{format_area(lp / 100.0)} соток"
      else
        "#{format_area(area_m2)} м²"
      end
    end

    # rooms in Topnlab encoding: 1..9 = number of rooms; ≥ 10 → studio code (only meaningful for flat/room).
    def rooms_title_part
      n = to_int(@p['rooms'])
      return nil if n.nil?
      type = @p['realty_type'].to_s
      if n > 9
        return nil unless %w[flat room].include?(type)
        return 'Студия'
      end
      "#{n}-комн."
    end

    def build_street_phrase
      street = ["#{@p['street_type']}".strip, @p['street_name']].compact.reject(&:blank?).join(' ').strip
      return nil if street.blank?
      house = @p['house'].presence ? ", д. #{@p['house']}" : ''
      "#{street}#{house}"
    end

    def format_area(v)
      return nil unless v
      f = v.to_f
      f == f.to_i ? f.to_i : f.round(1)
    end

    def pretty_realty_type
      {
        'flat'     => 'квартира',
        'room'     => 'комната',
        'house'    => 'дом',
        'land'     => 'участок',
        'commerce' => 'коммерция',
        'garage'   => 'гараж'
      }[(@p['realty_type'] || '').to_s] || 'объект'
    end

    def build_address
      parts = []
      parts << "#{@p['region_name']} #{@p['region_type']}".strip if @p['region_name'].present?
      parts << "#{@p['city_type']} #{@p['city_name']}".strip if @p['city_name'].present?
      parts << @p['folk_district_name'] if @p['folk_district_name'].present?
      street = ["#{@p['street_type']}".strip, @p['street_name']].compact.reject(&:blank?).join(' ')
      parts << street if street.present?
      house_part = ["д. #{@p['house']}".strip]
      house_part << "к#{@p['corpus']}" if @p['corpus'].present?
      house_part << "стр.#{@p['building']}" if @p['building'].present?
      parts << house_part.compact.join(' ') if @p['house'].present?
      parts << "кв. #{@p['flat']}" if @p['flat'].present?
      parts.reject(&:blank?).join(', ')
    end

    def build_description
      raw = @p['mydescription'].presence || @p['description'].presence
      return nil if raw.blank?
      # Strip HTML tags, decode entities.
      text = raw.gsub(/<\/?[^>]+>/, ' ').gsub(/\s+/, ' ').strip
      text = CGI.unescapeHTML(text)
      text[0, 4900]
    end

    def resolve_user_id
      email = @p.dig('user', 'email').to_s.downcase.presence
      if email && @agents[email]
        return @agents[email]
      end
      @fallback_user_id
    end

    def positive(v)
      f = v.to_f
      f.positive? ? f : nil
    end

    def positive_int(v)
      n = to_int(v)
      n&.positive? ? n : nil
    end

    def to_int(v)
      return nil if v.nil? || v == ''
      Integer(v.to_s, 10)
    rescue ArgumentError
      nil
    end

    def bool(v)
      v == true || v.to_s == 'true' || v.to_s == '1'
    end

    def bool_default(v, default)
      return default if v.nil?
      bool(v)
    end
  end
end
