# frozen_string_literal: true

# Automated Valuation Model (AVM) for a single Property — runs the existing
# PropertyEvaluation::Hedonic OLS regression against in-advertising comparables
# (same property_type + deal_type, ±20% area, ±1 room, same district or 5km radius).
#
# Built distinct from the PropertyValuation form pipeline (express + investment
# audit) because:
#   - It works on an already-saved Property, not a user-submitted hypothetical.
#   - It targets the property show page (read-heavy, must be cached).
#   - Result is a *valuation range* shown for transparency, not a lead-magnet
#     form output.
#
# Cached for 24h per Property; cache key includes updated_at so a price change
# or attribute edit triggers fresh recompute on next view.
class PropertyAvm
  CACHE_TTL = 24.hours
  MIN_COMPARABLES = 8
  AREA_BAND_PCT = 0.20
  ROOMS_DELTA = 1
  GEO_RADIUS_KM = 5

  Result = Struct.new(
    :estimate, :min_price, :max_price, :price_per_sqm,
    :n_used, :confidence_pct, :spread_pct,
    :sample_basis, :methodology,
    keyword_init: true
  ) do
    # True iff the AVM band is reasonably tight (±15% or less). Wider bands
    # mean the regression is uncertain — better to hide them from buyers than
    # show "5–15M ₽" which looks unprofessional.
    def reliable?
      spread_pct.to_f <= 30
    end
  end

  def self.call(property)
    new(property).call
  end

  def initialize(property)
    @property = property
  end

  def call
    return nil unless valid_property?

    Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { compute }
  rescue StandardError => e
    Rails.logger.warn("[PropertyAvm] property=#{@property.id} failed: #{e.class} #{e.message}")
    nil
  end

  private

  def cache_key
    "property_avm:v1:#{@property.id}:#{@property.updated_at.to_i}"
  end

  def valid_property?
    @property&.area.to_f.positive? &&
      @property.rooms.to_i.positive? &&
      @property.deal_type.present? &&
      @property.property_type_id.present?
  end

  def compute
    comparables = find_comparables
    return nil if comparables.size < MIN_COMPARABLES

    target = {
      rooms: @property.rooms.to_f,
      area:  @property.area.to_f,
      distance_km: 0.0
    }

    hedonic = PropertyEvaluation::Hedonic.call(comparables: comparables, target: target)
    return nil unless hedonic

    area      = @property.area.to_f
    estimate  = (hedonic.predicted_price_per_sqm * area).round(-3)
    min_price = (hedonic.ci_lo_95 * area).round(-3)
    max_price = (hedonic.ci_hi_95 * area).round(-3)
    spread    = estimate.positive? ? ((max_price - min_price).to_f / estimate * 100) : 0

    # residual_std is on the log scale; e^residual_std − 1 ≈ relative error.
    # Confidence here is "how tight" the model is, not statistical certainty.
    rel_error = Math.exp(hedonic.residual_std) - 1.0
    confidence = ((1.0 - rel_error) * 100).clamp(0, 99).round

    Result.new(
      estimate:       estimate,
      min_price:      min_price,
      max_price:      max_price,
      price_per_sqm:  hedonic.predicted_price_per_sqm.round,
      n_used:         hedonic.n_used,
      confidence_pct: confidence,
      spread_pct:     spread.round(1),
      sample_basis:   sample_basis_label,
      methodology:    methodology_text
    )
  end

  # Tiered comparable search mirrors PropertyEvaluation::ComparableFinder:
  # start strict (geo + rooms + tight area), relax progressively until we
  # have enough comparables or run out of tiers. Returns the first tier
  # with ≥ MIN_COMPARABLES; falls back to the loosest result otherwise.
  TIERS = [
    { area_pct: 0.20, rooms_delta: 0, geo: :radius_5km, label: 'строгий: ±20% площади, та же комнатность, 5 км' },
    { area_pct: 0.25, rooms_delta: 1, geo: :district,   label: 'район: ±25%, ±1 комната' },
    { area_pct: 0.30, rooms_delta: 2, geo: :city,       label: 'город: ±30%, ±2 комнаты' }
  ].freeze

  def find_comparables
    TIERS.each do |tier|
      candidates = build_scope(tier).limit(80).map { |p| comparable_hash(p) }
      @tier_label = tier[:label]
      return candidates if candidates.size >= MIN_COMPARABLES
    end
    # No tier hit the threshold — return the loosest set anyway. Hedonic
    # will reject it for being too small, which is the correct outcome.
    build_scope(TIERS.last).limit(80).map { |p| comparable_hash(p) }
  end

  def build_scope(tier)
    a = @property.area.to_f
    scope = Property.in_advertising
                    .where.not(id: @property.id)
                    .where(deal_type: @property.deal_type)
                    .where(property_type_id: @property.property_type_id)
                    .where('area > 0 AND price > 0')
                    .where(area: (a * (1 - tier[:area_pct]))..(a * (1 + tier[:area_pct])))

    if @property.rooms.to_i.positive?
      base = @property.rooms.to_i
      rooms_range = ((base - tier[:rooms_delta]).clamp(0, nil)..(base + tier[:rooms_delta])).to_a.uniq
      scope = scope.where(rooms: rooms_range)
    end

    apply_geo(scope, tier[:geo])
  end

  def apply_geo(scope, geo_mode)
    case geo_mode
    when :radius_5km
      if @property.latitude.present? && @property.longitude.present?
        scope.near([@property.latitude, @property.longitude], GEO_RADIUS_KM, units: :km)
      elsif @property.district.present?
        scope.where(district: @property.district)
      else
        scope
      end
    when :district
      @property.district.present? ? scope.where(district: @property.district) : scope
    when :city
      scope
    else
      scope
    end
  rescue StandardError => e
    Rails.logger.warn("[PropertyAvm##{__method__}] tier=#{@tier_label} fallback to base scope: #{e.class}: #{e.message.to_s.truncate(160)}")
    scope
  end

  def comparable_hash(other)
    pps = if other.price_per_sqm.to_i.positive?
            other.price_per_sqm.to_i
          else
            (other.price.to_f / other.area.to_f).round
          end
    {
      rooms:         other.rooms,
      area:          other.area.to_f,
      price_per_sqm: pps,
      distance_km:   distance_km_to(other) || 0.0
    }
  end

  def distance_km_to(other)
    return nil unless @property.latitude && @property.longitude &&
                      other.latitude && other.longitude

    Geocoder::Calculations.distance_between(
      [@property.latitude, @property.longitude],
      [other.latitude, other.longitude],
      units: :km
    )
  rescue StandardError => e
    Rails.logger.warn("[PropertyAvm#distance_km_to] property=#{@property.id} other=#{other&.id}: #{e.class}: #{e.message.to_s.truncate(120)}")
    nil
  end

  def sample_basis_label
    @tier_label.presence || 'активные объявления'
  end

  def methodology_text
    'Оценка построена на регрессии log(₽/м²) по комнатности, log(площади) ' \
      'и удалённости от объекта. База — активные объявления того же типа в ' \
      'радиусе 5 км или в том же районе. Это ориентир, не оферта.'
  end
end
