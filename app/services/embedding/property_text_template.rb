# frozen_string_literal: true

module Embedding
  # Builds the natural-language text that gets embedded for each Property.
  # Includes structural fields *and* the full property.description (per the
  # plan's decision to capture nuance from agent-written text).
  #
  # The model accepts up to 2048 input tokens; with average descriptions
  # ≤1500 chars (~500 tokens) we have plenty of headroom. As a safety net
  # we still truncate at 8000 chars in case Topnlab returns long blobs.
  module PropertyTextTemplate
    DESCRIPTION_HARD_LIMIT = 8000

    module_function

    # @param property [Property]
    # @return [String]
    def build(property)
      lines = []
      lines << header_line(property)
      lines << price_line(property)
      lines << condition_line(property)
      lines << amenities_line(property)
      lines << metro_line(property)
      lines << description_line(property)
      lines.compact.reject(&:empty?).join("\n")
    end

    PROPERTY_TYPE_RU = {
      'flat'     => 'Квартира',
      'room'     => 'Комната',
      'house'    => 'Дом',
      'land'     => 'Земельный участок',
      'commerce' => 'Коммерческая недвижимость',
      'garage'   => 'Гараж'
    }.freeze

    def header_line(p)
      bits = []
      bits << property_type_label(p)              # "Земельный участок", "Квартира", ...
      bits << p.rooms_info if p.respond_to?(:rooms_info) && p.rooms_info
      bits << area_label(p)
      floor = (p.floor && p.total_floors) ? "#{p.floor}/#{p.total_floors} этаж" : nil
      bits << floor if floor
      bits << "район #{p.district}" if p.district.present?
      bits << "адрес: #{p.address}" if p.address.present?
      bits.compact.reject(&:empty?).join(', ')
    end

    def property_type_label(p)
      slug = p.property_type&.slug
      PROPERTY_TYPE_RU[slug] # nil if unknown — header still has area/district
    end

    # For land we display сотки (1 сотка = 100 м²) as that's how plot sizes are
    # talked about in Russian listings; m² stays for built objects.
    # House with a separate plot embeds both: "120 кв.м на 8 соток".
    def area_label(p)
      return unless p.area

      slug = p.property_type&.slug
      if slug == 'land'
        sotki = (p.area.to_f / 100.0)
        sotki >= 1 ? format('%.1f соток (%.0f кв.м)', sotki, p.area) : format('%.0f кв.м', p.area)
      elsif slug == 'house' && p.respond_to?(:land_area_m2) && p.land_area_m2.to_f.positive?
        format('%.0f кв.м на %.1f соток', p.area, p.land_area_m2.to_f / 100.0)
      else
        format('%.0f кв.м', p.area)
      end
    end

    def price_line(p)
      return unless p.price

      "Цена #{p.price_formatted}. Сделка: #{deal_type_human(p.deal_type)}."
    end

    def condition_line(p)
      cond = condition_human(p.condition)
      year = p.building_year ? "#{p.building_year} г.п." : nil
      bld  = p.building_type
      [cond && "Состояние: #{cond}.", year, bld && "Тип дома: #{bld}."].compact.join(' ')
    end

    def amenities_line(p)
      a = []
      a << 'балкон/лоджия' if p.has_balcony || p.has_loggia
      a << 'парковка'      if p.has_parking
      a << 'лифт'          if p.has_elevator
      a << 'консьерж'      if p.has_concierge
      a << 'охрана'        if p.has_security
      a << 'можно с животными' if p.pets_allowed
      ceiling = p.ceiling_height && "потолки #{p.ceiling_height} м"
      a << ceiling if ceiling
      view = p.window_view && "вид: #{p.window_view}"
      a << view if view
      return if a.empty?

      "Особенности: #{a.join(', ')}."
    end

    def metro_line(p)
      return unless p.metro_station.present?

      dist = p.metro_distance
      txt = "Метро #{p.metro_station}"
      if dist
        minutes = (dist / 80.0).ceil # ~80 m/min walking
        txt += " (#{dist} м, ≈#{minutes} мин #{p.metro_transport.presence || 'пешком'})"
      end
      "#{txt}."
    end

    def description_line(p)
      desc = p.description.to_s.strip
      return if desc.empty?

      "Описание: #{desc.truncate(DESCRIPTION_HARD_LIMIT, omission: '…')}"
    end

    def deal_type_human(deal_type)
      { 'sale' => 'продажа', 'rent' => 'аренда', 'daily' => 'посуточная аренда' }[deal_type.to_s] || deal_type
    end

    def condition_human(c)
      {
        'needs_repair' => 'требует ремонта',
        'normal'       => 'обычное',
        'renovated'    => 'с ремонтом',
        'euro'         => 'евроремонт',
        'designer'     => 'дизайнерский ремонт'
      }[c.to_s]
    end
  end
end
