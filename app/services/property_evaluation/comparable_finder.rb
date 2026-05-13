# frozen_string_literal: true

# Tiered search for comparable listings (Property + MlsListing).
# Returns enriched comparables with computed price_per_sqm, distance_km, and weight.
#
# Algorithm: try tier 1 (3 km, area ±15%, exact rooms); if too few hits, relax to
# tier 2/3/4. Each tier widens the geometric/categorical bounds.
module PropertyEvaluation
  class ComparableFinder
    Tier = Struct.new(:radius_km, :area_pct, :rooms_delta, :scope_filter, keyword_init: true)

    TIERS = [
      Tier.new(radius_km: 3,   area_pct: 0.15, rooms_delta: 0, scope_filter: :geo),
      Tier.new(radius_km: 5,   area_pct: 0.20, rooms_delta: 1, scope_filter: :geo),
      Tier.new(radius_km: nil, area_pct: 0.25, rooms_delta: 2, scope_filter: :district),
      Tier.new(radius_km: nil, area_pct: 0.30, rooms_delta: 3, scope_filter: :city)
    ].freeze

    THRESHOLDS = [
      PropertyEvaluationService::MIN_TIER1,
      PropertyEvaluationService::MIN_TIER2,
      PropertyEvaluationService::MIN_TIER3,
      1
    ].freeze

    REALTY_TYPE_TO_SLUG = {
      'apartment' => 'flat', 'house' => 'house', 'land' => 'land',
      'commercial' => 'commerce', 'garage' => 'garage', 'room' => 'room'
    }.freeze

    def initialize(valuation)
      @v = valuation
    end

    def call
      TIERS.each_with_index do |tier, i|
        enriched = enrich(collect(tier))
        return { tier: i + 1, comparables: enriched } if enriched.size >= THRESHOLDS[i]
      end
      { tier: TIERS.size, comparables: enrich(collect(TIERS.last)) }
    end

    private

    def collect(tier)
      ([property_scope(tier).to_a, mls_scope(tier).to_a, external_scope(tier).to_a]
        .flatten
        .uniq { |r| [r.class.name, r.id] })
    end

    # Comparable data from third-party feeds (Yandex YRL of other Ryazan
    # agencies, future Avito API, etc). Same filters as `mls_scope` —
    # area-band, rooms-band, geo or district fallback.
    def external_scope(tier)
      slug = REALTY_TYPE_TO_SLUG[@v.property_type.to_s]
      return ExternalListing.none unless slug

      s = ExternalListing.active.priced.recent(60)
                         .for_deal(@v.deal_type)
                         .for_type(slug)
                         .area_band(@v.total_area.to_f, tier.area_pct)
                         .rooms_band(@v.rooms.to_i, tier.rooms_delta)
      apply_geo(s, tier).limit(50)
    end

    def property_scope(tier)
      pt_id = property_type_id_for(@v.property_type)
      return Property.none if pt_id.nil?

      s = Property.published.where('price > 0 AND area > 0')
                  .where(property_type_id: pt_id, deal_type: @v.deal_type)
      s = s.where(area: band(tier.area_pct))
      s = s.where(rooms: rooms_band(tier.rooms_delta)) if @v.rooms.present?
      apply_geo(s, tier).limit(50)
    end

    def mls_scope(tier)
      slug = REALTY_TYPE_TO_SLUG[@v.property_type.to_s]
      return MlsListing.none unless slug

      s = MlsListing.priced.recent(60)
                    .for_deal(@v.deal_type)
                    .realty(slug)
                    .area_band(@v.total_area, tier.area_pct)
                    .rooms_band(@v.rooms, tier.rooms_delta)
      apply_geo(s, tier).limit(50)
    end

    def apply_geo(scope, tier)
      case tier.scope_filter
      when :geo
        if @v.latitude.present? && @v.longitude.present? && tier.radius_km
          scope.near([@v.latitude, @v.longitude], tier.radius_km, units: :km)
        elsif @v.district.present? && has_column?(scope, 'district')
          scope.where(district: @v.district)
        else
          scope
        end
      when :district
        if @v.district.present? && has_column?(scope, 'district')
          scope.where(district: @v.district)
        else
          scope
        end
      when :city
        if @v.city.present? && has_column?(scope, 'city')
          scope.where(city: @v.city)
        else
          scope
        end
      else
        scope
      end
    end

    def has_column?(scope, column)
      scope.klass.column_names.include?(column)
    end

    def band(pct)
      a = @v.total_area.to_f
      (a * (1 - pct))..(a * (1 + pct))
    end

    def rooms_band(delta)
      base = @v.rooms.to_i
      ([base - delta, 1].max)..(base + delta)
    end

    def property_type_id_for(pt)
      slug = REALTY_TYPE_TO_SLUG[pt.to_s]
      return nil unless slug
      PropertyType.find_by(slug: slug)&.id
    end

    def enrich(records)
      records.filter_map do |r|
        pps = compute_pps(r)
        next nil if pps <= 0

        dist = distance_km_to(r)
        { record: r, price_per_sqm: pps, distance_km: dist,
          weight: dist ? 1.0 / (1.0 + dist) : 0.5 }
      end.sort_by { |c| c[:distance_km] || Float::INFINITY }
    end

    def compute_pps(record)
      explicit = record.try(:price_per_sqm)
      return explicit.to_i if explicit.to_i.positive?

      area_value = record.area.to_f
      return 0 unless area_value.positive?
      (record.price.to_f / area_value).round
    end

    def distance_km_to(r)
      return nil unless @v.latitude && @v.longitude && r.latitude && r.longitude
      Geocoder::Calculations.distance_between(
        [@v.latitude, @v.longitude],
        [r.latitude, r.longitude],
        units: :km
      )
    rescue StandardError
      nil
    end
  end
end
