# frozen_string_literal: true

# Translates a Topnlab MLS payload into MlsListing attributes.
# Mirrors Topnlab::PropertyMapper, but skips title/description/photos/property_type_id/user_id —
# MlsListing only needs the numeric/categorical attributes used by the valuation algorithm.
module MlsSync
  class ListingMapper
    DEAL_TYPE_MAP = { 'sale' => 'sale', 'rent' => 'rent', 'daily' => 'daily' }.freeze

    REALTY_TYPES = %w[flat room house land commerce garage].freeze

    CONDITION_MAP = {
      'norepair' => 'needs_repair', 'no_repair' => 'needs_repair', 'rough' => 'needs_repair',
      'cosmetic' => 'normal',       'standard' => 'normal',        'normal' => 'normal',
      'good' => 'renovated',        'renovated' => 'renovated',
      'euro' => 'euro',             'european' => 'euro',
      'designer' => 'designer',     'design' => 'designer'
    }.freeze

    def initialize(payload, source: 'topnlab_mls')
      @p = payload || {}
      @source = source
    end

    # @return [Hash, nil] attributes for MlsListing.assign_attributes — nil if unusable.
    def to_attributes
      return nil unless usable?

      {
        external_source: @source,
        external_id:     @p['id'].to_s,
        deal_type:       DEAL_TYPE_MAP[@p['action'].to_s] || 'sale',
        realty_type:     realty_type,
        price:           @p['price'].to_i,
        price_per_sqm:   price_per_sqm,
        area:            area,
        living_area:     positive(@p['living_area']),
        rooms:           sane_rooms,
        floor:           positive_int(@p['floor']),
        total_floors:    positive_int(@p['floors'] || @p['total_floors'] || @p['floors_count']),
        building_year:   positive_int(@p['build_year'] || @p['building_year']),
        building_type:   @p['wall_material'].presence,
        condition:       condition,
        address:         build_address,
        city:            @p['city_name'].presence,
        district:        @p['folk_district_name'].presence || @p['district_name'].presence,
        latitude:        @p['latitude'],
        longitude:       @p['longitude'],
        metro_station:   extract_metro_name(@p['metro']),
        metro_distance:  positive_int(@p['metro_distance']),
        has_balcony:     bool(@p['balcony'] || @p['has_balcony']),
        has_loggia:      to_int(@p['loggia_amount']).to_i.positive?,
        has_parking:     to_int(@p['parking']).to_i.positive?,
        has_elevator:    bool(@p['elevator'] || @p['has_elevator']),
        url:             @p['url'].presence,
        listed_at:       parse_time(@p['date_create'] || @p['created_at']),
        synced_at:       Time.current
      }
    end

    private

    # Topnlab/MLS API `metro` иногда String, иногда Array<Hash>. См.
    # детальный коммент в Topnlab::PropertyMapper#extract_metro_name.
    def extract_metro_name(raw)
      return nil if raw.blank?
      return raw if raw.is_a?(String) && !raw.start_with?('[', '{')
      return nil unless raw.is_a?(Array) && raw.any?

      main = raw.find { |h| (h['is_main'] == 1) || (h[:is_main] == 1) } || raw.first
      (main['station_name'] || main[:station_name]).presence
    end

    def usable?
      return false unless @p['id']
      return false unless REALTY_TYPES.include?(realty_type)
      return false unless @p['price'].to_f.positive?
      return false unless area && area.positive?
      return false if @p['latitude'].blank? || @p['longitude'].blank?
      true
    end

    def realty_type
      @p['realty_type'].to_s
    end

    def price_per_sqm
      raw = @p['price_per_meter']
      return raw.to_i if raw.to_f.positive?
      return nil unless area && area.positive?
      (@p['price'].to_f / area).round
    end

    def area
      a = @p['area'].to_f
      return a if a.positive?
      ppm = @p['price_per_meter'].to_f
      price = @p['price'].to_f
      (price / ppm).round(1) if ppm.positive? && price.positive?
    end

    def sane_rooms
      n = to_int(@p['rooms'])
      return nil if n.nil?
      return 1 if n > 9
      n.positive? ? n : nil
    end

    def condition
      raw = (@p['repair'] || @p['condition'] || @p['repair_type']).to_s.downcase.strip
      CONDITION_MAP[raw] || 'normal'
    end

    def build_address
      [@p['city_name'], @p['folk_district_name'].presence || @p['district_name'],
       [@p['street_type'].to_s.strip, @p['street_name']].reject(&:blank?).join(' '),
       (@p['house'].present? ? "д. #{@p['house']}" : nil)
      ].compact.reject(&:blank?).join(', ')
    end

    def parse_time(v)
      return nil if v.blank?
      Time.zone.parse(v.to_s)
    rescue ArgumentError, TypeError
      nil
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
  end
end
