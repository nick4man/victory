# frozen_string_literal: true

# SEO landings (M1-M3 from the audit plan): a programmatic URL pyramid for
# intent × type × {district | rooms}. Each landing has its own canonical, H1,
# meta, JSON-LD, and content slot — distinct from /properties so each can
# rank independently in Yandex/Google.
#
# URL examples:
#   /kupit/kvartira                      → cluster A
#   /kupit/kvartira/2-komnatnaya         → cluster B
#   /kupit/kvartira/rayon/kanishchevo    → cluster C
#   /snyat/dom                           → cluster A (rent side)
#
# Slugs in the URL are latin (transliterated). The controller maps them back
# to russian display names + PropertyType slugs via constants below. Unknown
# slugs raise RoutingError → 404 (Yandex penalises soft-404s heavily).
class LandingsController < ApplicationController
  # Per-type definitions: accusative (for "Купить ..." headlines), plural
  # (for "Найдено 12 квартир"), the Topnlab PropertyType.slug to filter by,
  # and whether rooms count makes sense for this type.
  TYPE_DEFINITIONS = {
    'kvartira' => {
      accusative: 'квартиру',
      plural_genitive: 'квартир',
      property_type_slug: 'flat',
      supports_rooms: true
    },
    'dom' => {
      accusative: 'дом',
      plural_genitive: 'домов',
      property_type_slug: 'house',
      supports_rooms: false
    },
    'uchastok' => {
      accusative: 'участок',
      plural_genitive: 'участков',
      property_type_slug: 'land',
      supports_rooms: false
    },
    'komnata' => {
      accusative: 'комнату',
      plural_genitive: 'комнат',
      property_type_slug: 'room',
      supports_rooms: false
    },
    'kommercheskaya' => {
      accusative: 'коммерческую недвижимость',
      plural_genitive: 'объектов коммерческой недвижимости',
      property_type_slug: 'commerce',
      supports_rooms: false
    }
  }.freeze

  INTENT_VERB = { 'sale' => 'Купить', 'rent' => 'Снять' }.freeze

  # Latin slug → list of accepted district strings as they appear in the
  # Property#district column. Multiple aliases handle CRM data variance
  # (e.g. "ДП" vs full "Дашково-Песочня").
  DISTRICT_MAP = {
    'kanishchevo'        => ['Канищево'],
    'dashkovo-pesochnya' => ['Дашково-Песочня', 'ДП'],
    'moskovskiy'         => ['Московский', 'Московский (народный)'],
    'sovetskiy'          => ['Советский'],
    'oktyabrskiy'        => ['Октябрьский'],
    'zheleznodorozhnyy'  => ['Железнодорожный'],
    'semchino'           => ['Семчино'],
    'priokskiy'          => ['Приокский'],
    'sokolovka'          => ['Соколовка'],
    'gorroshcha'         => ['Горроща'],
    'nedostoyevo'        => ['Недостоево'],
    'vostochnyy'         => ['Восточный', 'Восточный промузел']
  }.freeze

  def show
    @intent        = params[:intent] || 'sale'
    @type          = params[:type]
    @district_slug = params[:district]
    @rooms_raw     = params[:rooms]

    @type_def = TYPE_DEFINITIONS[@type]
    return render_not_found("Unknown type: #{@type}") unless @type_def

    if @district_slug
      @district_aliases = DISTRICT_MAP[@district_slug]
      return render_not_found("Unknown district: #{@district_slug}") unless @district_aliases
    end

    @rooms = parse_rooms(@rooms_raw)
    return render_not_found("Bad rooms: #{@rooms_raw}") if @rooms == :invalid
    return render_not_found("Rooms not valid for type #{@type}") if @rooms_raw && !@type_def[:supports_rooms]

    @properties  = build_scope.order(created_at: :desc).limit(48)
    @total_count = build_scope.count

    @h1               = build_h1
    @meta_title       = "#{@h1} | АН «Виктори»"
    @meta_description = build_meta_description
    @canonical_path   = request.path

    add_breadcrumb 'Каталог', properties_path
    add_breadcrumb @h1
  end

  private

  def build_scope
    deal_type = (@intent == 'rent' ? :rent : :sale)
    scope = Property.in_advertising.where(deal_type: deal_type)

    if (pt = PropertyType.find_by(slug: @type_def[:property_type_slug]))
      scope = scope.where(property_type_id: pt.id)
    end

    scope = scope.where(district: @district_aliases)         if @district_aliases
    scope = scope.where(rooms: @rooms)                       if @rooms
    scope
  end

  # 'studiya' → 0 (rooms=0 is the studio convention in Property); '1'..'4' → int.
  # nil → nil (no filter). Anything else → :invalid sentinel for 404.
  def parse_rooms(raw)
    case raw
    when nil then nil
    when 'studiya' then 0
    when /\A[1-4]\z/ then raw.to_i
    else :invalid
    end
  end

  def render_not_found(reason = nil)
    Rails.logger.info("[Landings] 404: #{reason}") if reason
    render template: 'errors/not_found', status: :not_found, formats: [:html]
  end

  def build_h1
    verb = INTENT_VERB[@intent] || 'Купить'
    head = if @rooms_raw == 'studiya' && @type == 'kvartira'
             'студию'
           elsif @rooms && @type == 'kvartira'
             rooms_label = @rooms == 1 ? '1-комнатную' : "#{@rooms}-комнатную"
             "#{rooms_label} #{@type_def[:accusative]}"
           else
             @type_def[:accusative]
           end
    location = @district_aliases ? "в районе #{@district_aliases.first}, Рязань" : 'в Рязани'
    "#{verb} #{head} #{location}"
  end

  def build_meta_description
    location = @district_aliases ? "в районе #{@district_aliases.first} (Рязань)" : 'в Рязани и Рязанской области'
    "#{@h1}. Подбор #{@type_def[:plural_genitive]} #{location} от АН «Виктори» — " \
      "#{@total_count} актуальных предложений, реальные фото, выезд агента, " \
      'сопровождение сделки. Звоните: ' + AgencyInfo::PHONE_PRIMARY
  end
end
