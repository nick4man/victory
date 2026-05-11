# frozen_string_literal: true

module AuditEngine
  # Builds the JSON payload for `POST /api/v2/audit/` out of a
  # PropertyValuation record. Maps Russian/Rails-side fields to the engine's
  # Pydantic schema (see services/audit-engine/SKILL_API_CONTRACT.md §4.1).
  #
  # The engine discriminates on `property_type` upper-cased; field set
  # varies per type (apartment_type only for APARTMENT, land_area_sotki for
  # HOUSE+LAND, etc.). Unknown fields are silently dropped by Pydantic, but
  # we keep payloads tight for log-readability.
  class AuditRequest
    # Engine apartment_type values: Studio, 1BR, 2BR, 3BR, 4BR, 5BR.
    # Rails `rooms` is an integer; map both ways.
    ROOMS_TO_APARTMENT_TYPE = {
      0 => 'Studio',
      1 => '1BR',
      2 => '2BR',
      3 => '3BR',
      4 => '4BR',
      5 => '5BR'
    }.freeze

    DEFAULT_HORIZON_YEARS = 5
    # Engine accepts these as optional; we send them only when the user
    # actually filled them in. Otherwise engine uses macro/latest defaults.

    def self.from_valuation(valuation)
      new(valuation).to_payload
    end

    def initialize(valuation)
      @v = valuation
    end

    def to_payload
      case @v.property_type
      when 'apartment', 'room' then apartment_payload
      when 'house'             then house_payload
      when 'land'              then land_payload
      when 'commercial'        then commercial_payload
      else
        # Engine treats unspecified `property_type` as APARTMENT for
        # backwards-compat; we surface this explicitly via assumptions.
        apartment_payload.merge(property_type: 'APARTMENT')
      end.compact
    end

    private

    def apartment_payload
      {
        property_type: 'APARTMENT',
        complex_name: complex_name,
        apartment_type: apartment_type,
        area_sqm: @v.total_area.to_f,
        price_total: estimated_price_total,
        monthly_rent: monthly_rent_estimate,
        mortgage_rate: macro_or_nil(:mortgage_rate),
        deposit_rate: macro_or_nil(:deposit_rate),
        price_growth_annual: macro_or_nil(:price_growth_annual),
        horizon_years: DEFAULT_HORIZON_YEARS,
        lat: @v.latitude&.to_f,
        lon: @v.longitude&.to_f
      }
    end

    def house_payload
      {
        property_type: 'HOUSE',
        object_name: object_name_for('Дом'),
        area_sqm: @v.total_area.to_f,
        land_area_sotki: @v.land_area&.to_f,
        price_total: estimated_price_total,
        monthly_rent: monthly_rent_estimate,
        mortgage_rate: macro_or_nil(:mortgage_rate),
        deposit_rate: macro_or_nil(:deposit_rate),
        price_growth_annual: macro_or_nil(:price_growth_annual),
        horizon_years: DEFAULT_HORIZON_YEARS,
        lat: @v.latitude&.to_f,
        lon: @v.longitude&.to_f
      }
    end

    def land_payload
      {
        property_type: 'LAND',
        object_name: object_name_for('Участок'),
        land_area_sotki: @v.land_area&.to_f,
        price_total: estimated_price_total,
        category: @v.land_category.presence || 'ИЖС',
        price_growth_annual: macro_or_nil(:price_growth_annual),
        deposit_rate: macro_or_nil(:deposit_rate),
        horizon_years: DEFAULT_HORIZON_YEARS,
        lat: @v.latitude&.to_f,
        lon: @v.longitude&.to_f
      }
    end

    # Engine has no first-class COMMERCIAL type; we fall back to APARTMENT
    # shape (works for office/retail by area×price/m²) and tag intent via
    # complex_name so reports stay readable.
    def commercial_payload
      apartment_payload.merge(
        complex_name: object_name_for('Коммерческая недвижимость'),
        apartment_type: '1BR' # MC pricing model needs a value; treat as single-unit
      )
    end

    def complex_name
      @v.address.presence || @v.district.presence || @v.city.presence || 'Объект'
    end

    def object_name_for(prefix)
      [prefix, @v.address.presence].compact.join(', ')[0, 200]
    end

    def apartment_type
      ROOMS_TO_APARTMENT_TYPE.fetch(@v.rooms.to_i, '2BR') if @v.rooms.present?
    end

    # User submits an asking price OR we use the locally-estimated price as
    # the price_total for investment-audit input. Engine needs SOME value.
    def estimated_price_total
      [@v.estimated_price, @v.max_price, fallback_price_estimate].compact.first.to_f
    end

    # Local fallback if no price provided yet: use ₽/m² × area from
    # PropertyEvaluationService FALLBACK_PRICES, but in `audit_engine`
    # context this should rarely fire — the Express estimator runs first.
    def fallback_price_estimate
      per_sqm = case @v.property_type
                when 'apartment', 'room' then 80_000
                when 'house'             then 60_000
                when 'land'              then 200_000
                when 'commercial'        then 100_000
                else 80_000
                end
      area = @v.total_area.presence || (@v.land_area_in_sqm if @v.respond_to?(:land_area_in_sqm))
      return nil unless area
      area.to_f * per_sqm
    end

    # Engine wants a monthly rent number to score 'rent-vs-buy' EI.
    # Naive 0.5%/month yield on price_total — engine treats this as a hint
    # and re-derives via MLS comparables when available.
    def monthly_rent_estimate
      price = estimated_price_total
      return nil unless price.positive?
      (price * 0.005).round
    end

    # Engine accepts mortgage_rate/deposit_rate/price_growth_annual as
    # optional. We forward two sources:
    #   1. Explicit user overrides stored in `evaluation_data.user_overrides`
    #      (from the Investment audit form's "use my own rates" toggle).
    #   2. Otherwise nil → engine uses macro_economics row written by its
    #      APScheduler (fresh ЦБ key rate ± derivations).
    def macro_or_nil(key)
      overrides = @v.evaluation_data&.dig('user_overrides')
      return nil unless overrides.is_a?(Hash)
      v = overrides[key.to_s] || overrides[key]
      v&.to_f if v.respond_to?(:to_f) && v.to_f.positive?
    end
  end
end
