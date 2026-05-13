# frozen_string_literal: true

module Valuations
  # When subject's home city has few or no real comps, we borrow comps
  # from a structurally similar city (same property_type, decent sample)
  # and rescale them via the city-median ratio:
  #
  #   adapted_pps = source_comp.pps * (target_city_median / source_city_median)
  #
  # The structural assumption: within Russia, a "1-bedroom apartment with
  # average condition" trades at roughly the same multiple of city median
  # across cities. So Moscow comps can stand in for Tula comps once their
  # nominal price is scaled by the Tula/Moscow median ratio.
  #
  # This is a coarse approximation — best for thinly-served subject cities
  # where the ensemble would otherwise lean entirely on the city-anchor.
  class CrossCityAdapter
    SOURCE_TAG       = 'cross_city_adapted'
    MIN_SOURCE_COMPS = 1   # катастрофически тонкий каталог — даже 1 донор лучше нуля. Поднимем когда каталог вырастет.
    MAX_COMPS        = 8   # cap returned

    # Donor-city preference order: largest cities first since they have
    # the deepest catalogs. Limited to Russian cities where we already
    # carry CityMedianPrice rows.
    DONOR_CITIES = %w[Москва Санкт-Петербург Краснодар Казань Екатеринбург Новосибирск Ростов-на-Дону].freeze

    def self.call(valuation)
      new(valuation).call
    end

    def initialize(valuation)
      @v = valuation
    end

    def call
      return [] if @v.city.blank? || @v.property_type.blank?

      target_median = CityMedianPrice.lookup(@v.city, @v.property_type)
      return [] if target_median.nil?

      donor = pick_donor_city(target_median)
      return [] unless donor

      donor_median = donor[:median]
      ratio = target_median.to_f / donor_median.to_f
      return [] if ratio <= 0

      source_comps = comps_from_donor(donor[:city])
      source_comps.first(MAX_COMPS).map { |c| adapt(c, ratio: ratio, donor_city: donor[:city]) }
    rescue StandardError => e
      Rails.logger.warn("[Valuations::CrossCityAdapter] #{e.class}: #{e.message.truncate(180)}")
      []
    end

    private

    # Donor = city that (a) has CityMedianPrice for our property_type,
    # (b) has at least MIN_SOURCE_COMPS published Properties of that type.
    # Prefer cities geographically closest to the subject (via Geocoder).
    def pick_donor_city(_target_median)
      DONOR_CITIES.reject { |c| c == @v.city }.filter_map { |city|
        median = CityMedianPrice.lookup(city, @v.property_type)
        next nil unless median&.positive?
        count = donor_comp_count(city)
        next nil if count < MIN_SOURCE_COMPS
        { city: city, median: median, count: count }
      }.first
    end

    def donor_comp_count(city)
      # Property doesn't have a `city` column; we approximate via address ILIKE.
      Property.published.where('address ILIKE ?', "%#{city}%").count
    end

    def comps_from_donor(city)
      pt_id = PropertyType.find_by(slug: realty_slug)&.id
      return [] unless pt_id

      Property.published
              .where(property_type_id: pt_id)
              .where('address ILIKE ?', "%#{city}%")
              .where('price > 0 AND area > 0')
              .order(updated_at: :desc)
              .limit(20)
              .to_a
    end

    REALTY_TYPE_TO_SLUG = {
      'apartment'  => 'flat',
      'house'      => 'house',
      'land'       => 'land',
      'commercial' => 'commerce',
      'garage'     => 'garage',
      'room'       => 'room'
    }.freeze

    def realty_slug
      REALTY_TYPE_TO_SLUG[@v.property_type.to_s]
    end

    def adapt(property, ratio:, donor_city:)
      original_price = property.price.to_i
      original_pps   = (original_price.to_f / property.area.to_f).round
      adapted_price  = (original_price * ratio).round
      adapted_pps    = (original_pps * ratio).round

      {
        title:           "#{property.title.to_s.truncate(50)} (адаптация из #{donor_city})",
        price:           adapted_price,
        price_per_sqm:   adapted_pps,
        area:            property.area.to_f,
        rooms:           property.rooms,
        district:        property.district,
        city:            @v.city,
        source:          SOURCE_TAG,
        donor_city:      donor_city,
        adaptation_ratio: ratio.round(3),
        original_pps:    original_pps,
        weight:          0.5,
        synthetic:       false  # real listing, just rescaled
      }
    end
  end
end
