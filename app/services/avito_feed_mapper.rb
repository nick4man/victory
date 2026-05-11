# frozen_string_literal: true

# Maps a Property to the Avito Autoload XML format.
#
# Documentation: https://www.avito.ru/autoload/documentation/templates
#
# Avito uses category-specific schemas (apartments use one set of fields,
# land uses another). This mapper emits the union of fields useful across
# realty categories; the template gates each field on type so the XML
# stays validator-clean.
#
# Strategically separate from PropertyFeedMapper (YRL) and CianFeedMapper
# because the field naming and category model differ dramatically:
# - Avito: Russian category names ("Квартиры"), separate OperationType.
# - YRL:   English category names, type + property-type pair.
# - CIAN:  English category concatenated with deal type (flatSale).
class AvitoFeedMapper
  # property_type slug → Avito Category (Russian, exactly as Avito expects).
  CATEGORY_MAP = {
    'flat'     => 'Квартиры',
    'room'     => 'Комнаты',
    'house'    => 'Дома, дачи, коттеджи',
    'land'     => 'Земельные участки',
    'commerce' => 'Коммерческая недвижимость',
    'garage'   => 'Гаражи и машиноместа'
  }.freeze

  # Property#deal_type → Avito OperationType.
  OPERATION_TYPE_MAP = {
    'sale'  => 'Продам',
    'rent'  => 'Сдам',
    'daily' => 'Сдам посуточно'
  }.freeze

  # Property#building_type → Avito HouseType (Russian, exact case).
  HOUSE_TYPE_MAP = {
    'panel'    => 'Панельный',
    'brick'    => 'Кирпичный',
    'monolith' => 'Монолитный',
    'block'    => 'Блочный',
    'wood'     => 'Деревянный',
    'stalin'   => 'Сталинский'
  }.freeze

  # Maximum length Avito allows in <Title>; longer titles get rejected at
  # autoload. Truncates with ellipsis so the original is still recognisable.
  TITLE_MAX = 100

  def initialize(property, host:, url_helpers: Rails.application.routes.url_helpers)
    @p           = property
    @host        = host
    @url_helpers = url_helpers
  end

  # @return [Hash, nil] ad hash; nil if category can't be resolved.
  def to_h
    category  = CATEGORY_MAP[@p.property_type&.slug]
    operation = OPERATION_TYPE_MAP[@p.deal_type]
    return nil unless category && operation

    {
      id:             @p.external_id.presence || "victory-#{@p.id}",
      date_begin:     @p.created_at.iso8601,
      ad_status:      'Free',
      listing_fee:    'Package',
      category:       category,
      operation_type: operation,
      property_rights: 'Посредник',
      property_type_slug: @p.property_type&.slug,
      manager_name:   AgencyInfo::NAME,
      contact_phone:  contact_phone,
      address:        @p.address.to_s.strip.presence,
      latitude:       @p.latitude&.to_f,
      longitude:      @p.longitude&.to_f,
      title:          truncate_title(@p.title),
      description:    description_text,
      price:          @p.price.to_i,
      square:         positive_decimal(@p.area),
      living_space:   positive_decimal(@p.living_area),
      kitchen_space:  positive_decimal(@p.kitchen_area),
      rooms:          (@p.rooms if @p.rooms.to_i.positive?),
      floor:          @p.floor,
      floors:         @p.total_floors,
      house_type:     HOUSE_TYPE_MAP[@p.building_type],
      built_year:     @p.building_year,
      balcony_or_loggia: balcony_or_loggia_value,
      images:         image_urls
    }.compact
  end

  private

  def contact_phone
    # Agent's personal number takes precedence over the agency line — Avito
    # routes its "позвонить" button straight to whatever is in <ContactPhone>.
    (@p.user&.phone.presence || AgencyInfo::PHONE_PRIMARY).to_s
  end

  def truncate_title(text)
    str = text.to_s.strip
    return nil if str.blank?
    str.length > TITLE_MAX ? "#{str[0, TITLE_MAX - 1]}…" : str
  end

  def description_text
    text = @p.description.to_s.strip
    return nil if text.blank?
    # Avito's hard limit is 7000 chars; keep some headroom.
    text.length > 6_800 ? "#{text[0, 6_800]}…" : text
  end

  def balcony_or_loggia_value
    has_balcony = @p.try(:has_balcony)
    has_loggia  = @p.try(:has_loggia)
    return 'Балкон и лоджия' if has_balcony && has_loggia
    return 'Балкон' if has_balcony
    return 'Лоджия' if has_loggia
    nil
  end

  def image_urls
    return [] unless @p.images.attached?
    # Avito's published cap is 40 images per ad — keeping aligned with the
    # 30 we use for YRL/CIAN so the feeds advertise the same gallery.
    @p.images.first(30).filter_map do |img|
      @url_helpers.rails_representation_url(img.variant(:hero), host: @host, protocol: 'https')
    rescue StandardError => e
      Rails.logger.warn("[AvitoFeedMapper] image url failed for blob ##{img.blob.id}: #{e.class} #{e.message}")
      nil
    end
  end

  def positive_decimal(value)
    f = value.to_f
    return nil unless f.positive?
    f == f.to_i ? f.to_i : f.round(2)
  end
end
