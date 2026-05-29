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

    # Topnlab rooms enum (verified via /realty/getoptions 18.05.26).
    # Поле `rooms` в realty payload — это NOT литеральное число комнат,
    # а enum-id кратный 10. См. .claude/docs/topnlab/listings-and-mls.md §3a.
    #
    # Convention: для студии — `rooms = 0` (matches Property#rooms_info).
    # Free planning (`id=99`) — оставляем nil + помечаем в title.
    ROOMS_ENUM_TO_COUNT = {
      10  => 0,           # Студия
      20  => 1,  30 => 2,  40 => 3,  50 => 4,  60 => 5,
      70  => 6,  80 => 7,  90 => 8, 100 => 9, 110 => 10,
      120 => 11, 130 => 12, 140 => 13, 150 => 14, 160 => 15,
      170 => 16, 180 => 17, 190 => 18, 200 => 19,
      205 => 20            # «20+ ком.» — cap at 20
    }.freeze
    ROOMS_FREE_PLANNING_CODE = 99

    # Для realty_type='room' (комната в общежитии/коммуналке) словарь
    # называется `rooms_for_room` — id означает «в N-комн. квартире/общаге»,
    # а не «N комнат в этом объекте». Сам listing — это всегда ОДНА комната.
    # Поэтому для type='room' мы оставляем Property.rooms = nil и формируем
    # title через room_type («Комната в общежитии», «Комната в коммуналке»).

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
        district:        RyazanDistricts.strip_folk_suffix(@p['folk_district_name'].presence || @p['district_name']),
        metro_station:   extract_metro_name(@p['metro']),
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
        deal_state:      @p['deal_state'].presence,
        # Topnlab tracks two independent advertising channels:
        # `in_ad`  — listing on agency's own site
        # `in_mls` — outbound MLS feed (Avito/Cian/etc.)
        # The public catalog should show objects active in EITHER channel.
        #
        # YRL launch Phase 1: для deal_state='ad' defaultim `in_mls=true`
        # если Topnlab его явно не передаёт. Без этого новые объекты
        # не попадают в `/feeds/yrl.xml` пока агент не выставит флаг
        # вручную в CRM. Бизнес-логика: «if it's in the public ad pipeline,
        # syndicate it».
        in_ad:           @p['in_ad']  == true,
        in_mls:          @p['in_mls'] == true || (@p['in_mls'].nil? && @p['deal_state'].to_s == 'ad'),
        closed_at:       derive_closed_at,
        synced_at:       Time.current
      }
      # NB: `status` and `published_at` are NOT set here — they belong to
      # `Property#publish_if_ready!`, which the Importer calls after save.
      # Letting mapper hardcode `status: :active` (the old behaviour) made
      # every re-import re-publish properties even when CRM had cleared
      # in_ad / moved them off deal_state=ad.

      # Property has NOT NULL constraints on title/price/address; area is now nullable
      # (objects without a real area get filtered from advertising scope, better than fake "1 м²").
      attrs[:title]   = "Объект #{@p['id']}"            if attrs[:title].blank?  || attrs[:title].length < 10
      attrs[:address] = attrs[:title]                    if attrs[:address].blank?
      # No description fallback: if CRM card lacks a real description, leave it
      # blank so `ready_for_site?` correctly refuses to publish.
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

    # Topnlab API возвращает `metro` иногда как String (одна станция), а
    # иногда как Array of Hash:
    # [{id:, station_name:, distance:, color:, is_main:1}, ...].
    # Property.metro_station — :string column. Assign Array → AR cast'ит в
    # .to_s → leak hash syntax в UI. Extract station_name из main station
    # (is_main:1) или первой в массиве. Если уже String — отдаём как есть.
    def extract_metro_name(raw)
      return nil if raw.blank?
      return raw if raw.is_a?(String) && !raw.start_with?('[', '{')
      return nil unless raw.is_a?(Array) && raw.any?

      main = raw.find { |h| (h['is_main'] == 1) || (h[:is_main] == 1) } || raw.first
      name = main['station_name'] || main[:station_name]
      name.presence
    end

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

    # When the realty card is `deal` (closed sale/rent), Topnlab includes a
    # nested `deals` block (requested via append=deals). Fields vary across
    # accounts, so try several known shapes in order of specificity, and
    # finally fall back to the entity's updated_at as a proxy for "closed when".
    def derive_closed_at
      return nil unless @p['deal_state'].to_s == 'deal'
      candidates = [
        @p.dig('deals', 0, 'date'),
        @p.dig('deals', 'date'),
        @p.dig('deal_data', 'date'),
        @p['date_done'],
        @p['deal_date'],
        @p['updated_at']
      ]
      candidates.each do |raw|
        next if raw.blank?
        parsed = Time.zone.parse(raw.to_s) rescue nil
        return parsed if parsed
      end
      nil
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

    # Convert Topnlab `rooms` enum-id → literal room count.
    # Returns nil если значение неизвестно / type='room' (см. ROOMS_ENUM_TO_COUNT).
    #
    # Fallback: если Topnlab прислал `rooms: null` (часто бывает при ручном
    # ленивом заполнении карточки), но `area_room` содержит площади-через-плюс
    # (`"19.1+6.7+6.6"`) — count parts. Это надёжный proxy для flat/house:
    # сами агенты в Topnlab пишут площадь каждой комнаты отдельно.
    def sane_rooms
      type = @p['realty_type'].to_s
      return nil if type == 'room'                         # см. комментарий ниже
      n = to_int(@p['rooms'])
      if n
        return nil if n == ROOMS_FREE_PLANNING_CODE        # свободная планировка
        mapped = ROOMS_ENUM_TO_COUNT[n]
        return mapped if mapped
      end
      # #1 Шаг 1 — fallback chain: area_room heuristic → description parsing
      # → nil. PropertyRoomsParser handles freeform Russian («3-комн.»,
      # «трёхкомнатная», «студия»→0 etc).
      derive_rooms_from_area_room ||
        PropertyRoomsParser.parse(@p['mydescription'] || @p['description'])
    end

    # Heuristic fallback: "19.1+6.7+6.6" → 3 комнаты.
    # Применяется только к flat/house где `rooms` enum пустой.
    def derive_rooms_from_area_room
      type = @p['realty_type'].to_s
      return nil unless %w[flat house].include?(type)
      raw = @p['area_room'].to_s.strip
      return nil if raw.empty?
      # Split по '+', оставляем только нумерические части (filter '0', '' etc).
      parts = raw.split('+').map(&:strip).reject(&:blank?).select { |s| s.to_f.positive? }
      return nil if parts.empty?
      [parts.size, 20].min  # cap at 20 — sanity
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
      district    = RyazanDistricts.strip_folk_suffix(
        @p['folk_district_name'].presence || @p['district_name'].presence
      ).presence
      city        = @p['city_name'].presence || @p['region_name'].presence
      street      = build_street_phrase

      # Lead with realty type; e.g. "1-комн. квартира" or just "Студия".
      # SELF_CONTAINED_LABELS уже содержат указание типа (Студия / Комната
      # в общежитии / Свободная планировка) — суффикс «квартира» не нужен.
      head = if SELF_CONTAINED_TITLE_LABELS.include?(rooms_label)
               rooms_label
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

    # Label-часть title для секции «N-комн. / Студия / Свободная планировка
    # / Комната в общежитии». Использует тот же enum что и `sane_rooms`,
    # но возвращает строку для human-readable title.
    def rooms_title_part
      type = @p['realty_type'].to_s

      # realty_type='room' — отдельная ветка через room_type.
      if type == 'room'
        return ROOM_TYPE_TITLES[to_int(@p['room_type'])] || 'Комната'
      end

      raw = to_int(@p['rooms'])
      return 'Свободная планировка' if raw == ROOMS_FREE_PLANNING_CODE

      # Reuses sane_rooms logic — includes area_room fallback для пустых
      # CRM-карточек. Источник истины один.
      count = sane_rooms
      return nil if count.nil?
      return 'Студия' if count.zero?
      "#{count}-комн."
    end

    # room_type enum из /realty/getoptions (key='room_type'):
    ROOM_TYPE_TITLES = {
      1 => 'Комната в общежитии',
      2 => 'Комната в коммунальной квартире',
      3 => 'Комната'        # «Стандартная квартира» — комната в стандартной кв.
    }.freeze

    # Labels that уже описывают realty_type — в build_title не добавляем
    # суффикс «квартира» к ним.
    SELF_CONTAINED_TITLE_LABELS = (
      ['Студия', 'Свободная планировка'] + ROOM_TYPE_TITLES.values
    ).freeze

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
      # Topnlab отдаёт «Московский (народный)» — stripping «(народный)»
      # для consistent display (см. RyazanDistricts#strip_folk_suffix).
      folk = RyazanDistricts.strip_folk_suffix(@p['folk_district_name'])
      parts << folk if folk.present?
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
