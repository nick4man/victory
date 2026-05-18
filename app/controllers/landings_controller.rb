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

  # Per-city DISTRICT_MAP — district slug → SQL alias values. Built lazily
  # via `Cities.districts_module(@city_slug)` so MoscowDistricts/SpbDistricts
  # adding rows в 1.6.C автоматически попадают в lookup без edit'a here.
  def district_map_for(city_slug)
    mod = Cities.districts_module(city_slug)
    (mod::MICRO.merge(mod::ADMIN)).transform_values { |v| v[:aliases] }
  end

  def show
    # 15-minute public cache — landings aggregate Property.on_site
    # and LandingContent; both change on Topnlab sync (hourly) and admin
    # edits (sporadic). 15 min is a safe compromise between freshness for
    # users and crawl-rate savings for Yandex/Google. Yandex pages with
    # consistent fast TTFB get higher crawl quotas.
    expires_in 15.minutes, public: true

    @city_slug     = params[:city] || Cities::DEFAULT_SLUG  # 'ryazan' default
    @city          = Cities.find(@city_slug)
    return render_not_found("Unknown city: #{@city_slug}") unless @city

    @intent        = params[:intent] || 'sale'
    @type          = params[:type]
    @district_slug = params[:district]
    @rooms_raw     = params[:rooms]
    @modifier      = params[:modifier] # 'premium' | nil

    @type_def = TYPE_DEFINITIONS[@type]
    return render_not_found("Unknown type: #{@type}") unless @type_def
    return render_not_found("Unknown modifier: #{@modifier}") if @modifier && @modifier != 'premium'

    if @district_slug
      @district_aliases = district_map_for(@city_slug)[@district_slug]
      return render_not_found("Unknown district: #{@district_slug} (city: #{@city_slug})") unless @district_aliases
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

    # DB-backed editorial content (admin-editable). If found and published,
    # the view renders it instead of the file-backed ERB partial. The
    # partial path is preserved as fallback for landings without a DB row
    # yet (gradual rollout). Modifier (premium) routes lookup through the
    # rooms slot as a convenience — LandingContent doesn't have a dedicated
    # modifier column yet (added if /premium picks up traction).
    lookup_rooms = @rooms_raw || @modifier
    @landing_content = LandingContent.for_landing(
      intent: @intent, type: @type,
      district_slug: @district_slug, rooms: lookup_rooms
    ).published.first

    add_breadcrumb 'Каталог', properties_path
    add_breadcrumb @h1
  end

  private

  def build_scope
    deal_type = (@intent == 'rent' ? :rent : :sale)
    scope = Property.on_site.where(deal_type: deal_type)

    if (pt = PropertyType.find_by(slug: @type_def[:property_type_slug]))
      scope = scope.where(property_type_id: pt.id)
    end

    # Phase 1.6 — filter by canonical city. For Рязань default (no city
    # prefix в route) сохраняем строгий filter тоже — иначе landings без
    # district вернули бы listings из всех cities в каталоге.
    scope = scope.in_city(@city[:name])                      if @city
    scope = scope.where(district: @district_aliases)         if @district_aliases
    scope = scope.where(rooms: @rooms)                       if @rooms
    scope = scope.premium                                    if @modifier == 'premium'
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
    qualifier = @modifier == 'premium' ? 'премиум ' : ''
    head = if @rooms_raw == 'studiya' && @type == 'kvartira'
             'студию'
           elsif @rooms && @type == 'kvartira'
             rooms_label = @rooms == 1 ? '1-комнатную' : "#{@rooms}-комнатную"
             "#{rooms_label} #{@type_def[:accusative]}"
           else
             @type_def[:accusative]
           end
    # @city always set по show action; canonical name used in H1.
    city_name = @city[:name]
    location = @district_aliases ? "в районе #{@district_aliases.first}, #{city_name}" : "в #{declination_in(city_name)}"
    "#{verb} #{qualifier}#{head} #{location}"
  end

  def build_meta_description
    city_name = @city[:name]
    region    = @city[:region]
    location = if @district_aliases
                 "в районе #{@district_aliases.first} (#{city_name})"
               elsif city_name == region
                 # Города федерального значения (Москва, СПб) — нет смысла
                 # повторять «в Москве и Москва»; используем только город.
                 "в #{declination_in(city_name)}"
               else
                 "в #{declination_in(city_name)} и #{declination_region_prep(region)}"
               end
    # Avg price/m² — динамический live signal в meta description для CTR-boost.
    # Я. читает meta description при ranking и часто использует как SERP snippet
    # → конкретные цифры > generic «подбор». Computed только если N≥5
    # (иначе число шумное и звучит подозрительно низко/высоко).
    price_clause = avg_price_clause_for_meta
    if @modifier == 'premium'
      "#{@h1}. Премиум-сегмент от АН «Виктори»: #{@total_count} актуальных " \
        "#{@type_def[:plural_genitive]} #{location}#{price_clause}, объекты от 15 млн ₽, " \
        'банки-партнёры, юридическое сопровождение, конфиденциальность. Звоните: ' + AgencyInfo::PHONE_PRIMARY
    else
      "#{@h1}. Подбор #{@type_def[:plural_genitive]} #{location} от АН «Виктори» — " \
        "#{@total_count} актуальных предложений#{price_clause}, реальные фото, выезд агента, " \
        'сопровождение сделки. Звоните: ' + AgencyInfo::PHONE_PRIMARY
    end
  end

  def avg_price_clause_for_meta
    return '' if @total_count.to_i < 5

    avg = build_scope.where('price_per_sqm > 0').average(:price_per_sqm)
    return '' if avg.blank? || avg <= 0

    # Округляем до тысяч (signal accurate но не показывает копейки)
    formatted = ActionController::Base.helpers.number_with_delimiter(avg.round(-3).to_i, delimiter: ' ')
    ", средняя цена #{formatted} ₽/м²"
  rescue StandardError => e
    Rails.logger.warn("[LandingsController] avg_price_clause failed: #{e.class}: #{e.message}")
    ''
  end

  # «Рязань» → «Рязани», «Москва» → «Москве», «Санкт-Петербург» →
  # «Санкт-Петербурге» (prepositional case). Manual map — Russian has
  # no clean rule applicable across all toponyms.
  def declination_in(city_name)
    case city_name
    when 'Москва'          then 'Москве'
    when 'Санкт-Петербург' then 'Санкт-Петербурге'
    when 'Рязань'          then 'Рязани'
    else                        city_name # неизвестный город — fallback nominative
    end
  end

  # Region in prepositional case (where? в Рязанской области, в Московской
  # области). Russian feminine adjective + noun pair — нет clean rule,
  # hardcode 4 нужных регионов. Federal cities don't pass через эту функцию.
  def declination_region_prep(region)
    case region
    when 'Рязанская область'   then 'Рязанской области'
    when 'Московская область'  then 'Московской области'
    else                            region # fallback nominative
    end
  end
end
