# frozen_string_literal: true

# Helpers for /zhk public pages (ResidentialComplex entity-страницы).
# Presentation only — domain logic живёт в ResidentialComplex/ListingStats.
module ZhkHelper
  HOUSING_CLASS_LABELS = {
    'econom' => 'эконом', 'comfort' => 'комфорт', 'business' => 'бизнес', 'elite' => 'элит'
  }.freeze

  BUILD_STATUS_LABELS = {
    'planned' => 'проектируется', 'under_construction' => 'строится', 'completed' => 'сдан'
  }.freeze

  # Per-file alt-теги для фото ЖК в `public/images/zhk/<slug>/` — та же
  # конвенция, что `LandingsHelper::DISTRICT_PHOTO_ALTS`/`#alt_for_district_photo`.
  # Пусто до тех пор, пока в проде не появятся реальные фото ЖК (см. отчёт).
  ZHK_PHOTO_ALTS = {}.freeze

  def alt_for_zhk_photo(complex_slug, filename, fallback: nil)
    ZHK_PHOTO_ALTS.dig(complex_slug, filename) || fallback || ''
  end

  # «От X ₽» — округление вниз до 100 тыс., то же правило что
  # `LandingsController#min_price_for_meta` (landings_controller.rb:257).
  def zhk_format_min_price(min_price)
    return nil if min_price.blank? || min_price.to_f <= 0

    number_with_delimiter((min_price.to_i / 100_000) * 100_000, delimiter: ' ')
  end

  # Средняя цена за м² — округление до тысяч, то же правило что
  # `LandingsController#avg_price_clause_for_meta` (landings_controller.rb:240).
  def zhk_format_avg_price_per_sqm(avg_price_per_sqm)
    return nil if avg_price_per_sqm.blank? || avg_price_per_sqm.to_f <= 0

    number_with_delimiter(avg_price_per_sqm.round(-3).to_i, delimiter: ' ')
  end

  # Cities::REGISTRY entry по canonical-имени города ЖК (обратный lookup,
  # презентационная копия приватного ResidentialComplex#city_slug — модель
  # не отдаёт его наружу, а здесь это чисто вопрос вёрстки geo.* meta).
  def zhk_city_config(complex)
    slug = Cities::REGISTRY.find { |_slug, cfg| cfg[:name] == complex.city }&.first
    slug ? Cities.find(slug) : nil
  end

  # Schema.org ApartmentComplex как Hash (НЕ script-тег) — композируется в
  # общий `@graph` вместе с CollectionPage/ItemList и BreadcrumbList на
  # странице ЖК. `ApartmentComplex` — подтип Residence, точнее чем общий
  # Place: даёт `numberOfAvailableAccommodationUnits` и `amenityFeature`.
  def apartment_complex_jsonld(complex, stats:, url:)
    amenity_names = {
      'Парковка' => complex.has_parking,
      'Закрытый двор' => complex.has_closed_yard,
      'Детская площадка' => complex.has_playground,
      'Детский сад' => complex.has_kindergarten,
      'Школа' => complex.has_school
    }.select { |_name, present| present }.keys

    node = {
      '@type' => 'ApartmentComplex',
      'name' => complex.display_name,
      'url' => url,
      'description' => complex.meta_description.presence || complex.title.presence,
      'address' => {
        '@type' => 'PostalAddress',
        'streetAddress' => complex.address,
        'addressLocality' => complex.city,
        'addressCountry' => 'RU'
      }.compact,
      'geo' => geo_coordinates_for(complex),
      'numberOfAvailableAccommodationUnits' => stats.count,
      'amenityFeature' => amenity_names.map { |name|
        { '@type' => 'LocationFeatureSpecification', 'name' => name, 'value' => true }
      },
      'additionalProperty' => additional_properties_for(complex)
    }.compact
    node.delete('amenityFeature') if node['amenityFeature'].blank?
    node.delete('additionalProperty') if node['additionalProperty'].blank?
    node
  end

  private

  def geo_coordinates_for(complex)
    return nil if complex.latitude.blank? || complex.longitude.blank?

    { '@type' => 'GeoCoordinates', 'latitude' => complex.latitude, 'longitude' => complex.longitude }
  end

  def additional_properties_for(complex)
    props = []
    if complex.developer.present?
      props << { '@type' => 'PropertyValue', 'name' => 'Застройщик', 'value' => complex.developer }
    end
    if complex.built_from.present?
      years = [complex.built_from, complex.built_to].compact.uniq.join('–')
      props << { '@type' => 'PropertyValue', 'name' => 'Год сдачи', 'value' => years }
    end
    if complex.housing_class.present?
      props << { '@type' => 'PropertyValue', 'name' => 'Класс жилья',
                  'value' => HOUSING_CLASS_LABELS.fetch(complex.housing_class, complex.housing_class) }
    end
    props
  end
end
