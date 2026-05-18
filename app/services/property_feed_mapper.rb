# frozen_string_literal: true

# Maps a Property to the YRL (Yandex Realty XML) feed format. Used by
# FeedsController to expose /feeds/yrl.xml — accepted by Yandex.Недвижимость
# and (with subset of fields) by ЦИАН / МирКвартир / Restate / Domofond.
#
# Spec reference: https://yandex.ru/support/realty/realty-feed-info.html
#
# Designed as a per-property mapper (not a batch) so the XML builder can
# stream offer-by-offer and never hold the full catalog in memory.
class PropertyFeedMapper
  # Topnlab/Property property_type slug → YRL category + property-type.
  CATEGORY_MAP = {
    'flat'     => { category: 'квартира',          property_type: 'жилая' },
    'room'     => { category: 'комната',           property_type: 'жилая' },
    'house'    => { category: 'дом',               property_type: 'жилая' },
    'land'     => { category: 'участок',           property_type: 'жилая' },
    'commerce' => { category: 'коммерческая',      property_type: 'коммерческая' },
    'garage'   => { category: 'гараж',             property_type: 'жилая' }
  }.freeze

  DEAL_TYPE_MAP  = { 'sale' => 'продажа', 'rent' => 'аренда', 'daily' => 'аренда' }.freeze
  RENT_PERIOD    = { 'sale' => nil,       'rent' => 'месяц',  'daily' => 'сутки' }.freeze

  BUILDING_TYPE_MAP = {
    'panel'    => 'панельный',
    'brick'    => 'кирпичный',
    'monolith' => 'монолит',
    'block'    => 'блочный',
    'wood'     => 'деревянный',
    'stalin'   => 'сталинский'
  }.freeze

  CONDITION_MAP = {
    'needs_repair' => 'требует ремонта',
    'normal'       => 'обычное',
    'renovated'    => 'косметический ремонт',
    'euro'         => 'евроремонт',
    'designer'     => 'дизайнерский ремонт'
  }.freeze

  def initialize(property, host:, url_helpers: Rails.application.routes.url_helpers)
    @p           = property
    @host        = host
    @url_helpers = url_helpers
  end

  def to_h
    cat_info = CATEGORY_MAP[@p.property_type&.slug] || CATEGORY_MAP['flat']
    {
      internal_id:      @p.external_id.presence || "victory-#{@p.id}",
      type:             DEAL_TYPE_MAP[@p.deal_type] || 'продажа',
      property_type:    cat_info[:property_type],
      category:         cat_info[:category],
      url:              property_full_url,
      creation_date:    @p.created_at.iso8601,
      last_update_date: @p.updated_at.iso8601,
      location:         location_hash,
      sales_agent:      sales_agent_hash,
      price:            price_hash,
      area:             area_hash(@p.area),
      living_space:     area_hash(@p.living_area),
      kitchen_space:    area_hash(@p.kitchen_area),
      rooms:            (@p.rooms if @p.rooms.to_i.positive?),
      floor:            @p.floor,
      floors_total:     @p.total_floors,
      built_year:       @p.building_year,
      building_type:    BUILDING_TYPE_MAP[@p.building_type],
      renovation:       CONDITION_MAP[@p.condition],
      balcony:          balcony_value,
      description:      description_text,
      images:           image_urls
    }.compact
  end

  private

  # Force https:// — раньше property_url возвращал http:// для feeds
  # (default protocol unset вне controller context). Aggregators
  # (Yandex.Realty/CIAN/Avito) валидаторы предпочитают canonical https://.
  def property_full_url
    @url_helpers.property_url(@p, host: @host, protocol: 'https')
  end

  def location_hash
    {
      country:      'Российская Федерация',
      region:       'Рязанская область',
      locality:     'Рязань',
      sub_locality: @p.district.presence,
      address:      @p.address.presence,
      latitude:     @p.latitude&.to_f,
      longitude:    @p.longitude&.to_f
    }.compact
  end

  def sales_agent_hash
    agent = @p.user
    {
      name:         (agent&.full_name.presence || AgencyInfo::NAME),
      phone:        (agent&.phone.presence || AgencyInfo::PHONE_PRIMARY),
      category:     'агентство',
      organization: AgencyInfo::NAME,
      url:          AgencyInfo::WEBSITE_URL,
      email:        AgencyInfo::EMAIL
    }.compact
  end

  def price_hash
    {
      value:    @p.price.to_i,
      currency: 'RUB',
      period:   RENT_PERIOD[@p.deal_type]
    }.compact
  end

  def area_hash(value)
    return nil unless value.to_f.positive?
    { value: format_number(value), unit: 'кв. м' }
  end

  def balcony_value
    return 'лоджия и балкон' if @p.try(:has_balcony) && @p.try(:has_loggia)
    return 'балкон' if @p.try(:has_balcony)
    return 'лоджия' if @p.try(:has_loggia)
    nil
  end

  def description_text
    text = @p.description.to_s.strip
    return nil if text.blank?
    # Yandex caps description at ~10k chars; trim with ellipsis to be safe.
    text.length > 9_000 ? "#{text[0, 9_000]}…" : text
  end

  def image_urls
    return [] unless @p.images.attached?
    # Cap at 30 — Yandex Realty's published limit per offer.
    # rails_representation_url with explicit host: works outside controller
    # context (mapper is a PORO; url_for(variant) without host would raise).
    @p.images.first(30).filter_map do |img|
      @url_helpers.rails_representation_url(img.variant(:hero), host: @host, protocol: 'https')
    rescue StandardError => e
      Rails.logger.warn("[PropertyFeedMapper] image url failed for blob ##{img.blob.id}: #{e.class} #{e.message}")
      nil
    end
  end

  def format_number(value)
    f = value.to_f
    f == f.to_i ? f.to_i : f.round(2)
  end
end
