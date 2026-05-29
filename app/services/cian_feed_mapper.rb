# frozen_string_literal: true

# Maps a Property to the ЦИАН feed format. CIAN doesn't accept the Yandex
# Realty XML (YRL) spec — they have their own XSD with different category
# slugs, nested BargainTerms/Building blocks, and phone splitting.
#
# Documentation: https://www.cian.ru/help/exchange/feeds/
#
# Strategically separate from PropertyFeedMapper because category logic is
# very different (CIAN concatenates deal_type into the category — flatSale
# vs flatRent — instead of having a separate <type> tag like YRL).
class CianFeedMapper
  # property_type slug + deal_type → CIAN category. CIAN treats sale/rent/
  # daily as part of the category name itself, so this matrix needs all
  # 3 verbs for every supported type.
  CATEGORY_MAP = {
    'flat' => {
      'sale'  => 'flatSale',
      'rent'  => 'flatRent',
      'daily' => 'flatRentDaily'
    },
    'room' => {
      'sale' => 'roomSale',
      'rent' => 'roomRent'
    },
    'house' => {
      'sale' => 'houseSale',
      'rent' => 'houseRent'
    },
    'land' => {
      'sale' => 'landSale',
      'rent' => 'landRent'
    },
    'commerce' => {
      'sale' => 'officeSale',
      'rent' => 'officeRent'
    },
    'garage' => {
      'sale' => 'garageSale',
      'rent' => 'garageRent'
    }
  }.freeze

  # Property#building_type slug → CIAN MaterialType. Defaults nil if no match.
  MATERIAL_TYPE_MAP = {
    'brick'    => 'brick',
    'panel'    => 'panel',
    'monolith' => 'monolith',
    'block'    => 'block',
    'wood'     => 'wood',
    'stalin'   => 'stalin'
  }.freeze

  # Property#condition → CIAN Decoration.
  DECORATION_MAP = {
    'needs_repair' => 'without',
    'normal'       => 'cosmetic',
    'renovated'    => 'good',
    'euro'         => 'euro',
    'designer'     => 'design'
  }.freeze

  def initialize(property, host:, url_helpers: Rails.application.routes.url_helpers)
    @p           = property
    @host        = host
    @url_helpers = url_helpers
  end

  # @return [Hash, nil] feed hash; nil if category can't be resolved (CIAN
  #   rejects offers without a category, so skipping the offer is correct).
  def to_h
    type_slug = @p.property_type&.slug
    category  = CATEGORY_MAP.dig(type_slug, @p.deal_type)
    return nil unless category

    {
      external_id:        @p.external_id.presence || "victory-#{@p.id}",
      category:           category,
      description:        @p.description.to_s.strip.presence,
      address:            @p.address.to_s.strip,
      url:                @url_helpers.property_url(@p, host: @host),
      coordinates:        coordinates_hash,
      phones:             phones_array,
      photos:             photos_array,
      bargain_terms:      bargain_terms_hash,
      total_area:         positive_decimal(@p.area),
      living_area:        positive_decimal(@p.living_area),
      kitchen_area:       positive_decimal(@p.kitchen_area),
      rooms_count:        (@p.rooms if @p.rooms.to_i.positive?),
      floor_number:       @p.floor,
      land:               land_hash(type_slug),
      building:           building_hash,
      decoration:         DECORATION_MAP[@p.condition],
      has_loggia:         @p.try(:has_loggia),
      has_balcony:        @p.try(:has_balcony),
      mortgage_allowed:   @p.try(:mortgage_allowed),
      last_update_date:   @p.updated_at.iso8601
    }.compact
  end

  private

  def coordinates_hash
    return nil unless @p.latitude && @p.longitude
    { lat: @p.latitude.to_f, lng: @p.longitude.to_f }
  end

  # CIAN wants phone split into +N CountryCode + bare-digits Number. Reuses
  # AgencyInfo as the source of truth — agent's personal phone goes in
  # SalesAgent (not modelled here yet); the agency line on Phones is what
  # CIAN's "позвонить" button dials.
  def phones_array
    raw = (@p.user&.phone.presence || AgencyInfo::PHONE_PRIMARY).to_s
    digits = raw.gsub(/\D/, '')
    return [] if digits.length < 11
    # Russian numbers come either as 8XXXXXXXXXX or 7XXXXXXXXXX; CIAN wants +7.
    country_code = "+#{digits[0] == '7' ? '7' : '7'}"
    number       = digits[-10..]
    [{ country_code: country_code, number: number }]
  end

  def photos_array
    return [] unless @p.images.attached?
    # CIAN's published cap is 50 per offer; capping at 30 to match YRL feed.
    @p.images.first(30).each_with_index.filter_map do |img, i|
      url = (@url_helpers.rails_representation_url(img.variant(:hero), host: @host, protocol: 'https') rescue nil)
      next nil unless url
      { full_url: url, is_default: i.zero? }
    end
  end

  def bargain_terms_hash
    base = {
      price:           @p.price.to_i,
      currency:        'rur',
      price_type:      'all',
      mortgage_allowed: @p.try(:mortgage_allowed)
    }
    # Rent-only fields: CIAN expects LeasePeriod (longTerm / shortTerm) plus
    # explicit MinLeaseTerm in days for monthly rent.
    if @p.deal_type == 'rent'
      base[:lease_period] = 'longTerm'
    elsif @p.deal_type == 'daily'
      base[:lease_period] = 'shortTerm'
    end
    base.compact
  end

  # CIAN's Land element applies only to land/house categories with a plot.
  # We expose land area in соток (CIAN's AreaUnitType=sotka) when present.
  def land_hash(type_slug)
    return nil unless %w[land house].include?(type_slug)
    land_m2 = @p.try(:land_area_m2)
    return nil unless land_m2.to_f.positive?
    sotki = (land_m2.to_f / 100.0).round(2)
    { area: sotki, area_unit_type: 'sotka' }
  end

  def building_hash
    parts = {
      floors_count:   @p.total_floors,
      build_year:     @p.building_year,
      material_type:  MATERIAL_TYPE_MAP[@p.building_type],
      passenger_lifts_count: (1 if @p.try(:has_elevator))
    }.compact
    parts.any? ? parts : nil
  end

  def positive_decimal(value)
    f = value.to_f
    return nil unless f.positive?
    f == f.to_i ? f.to_i : f.round(2)
  end
end
