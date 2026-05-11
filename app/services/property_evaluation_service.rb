# frozen_string_literal: true

# Orchestrates a property valuation: locates comparable listings via
# PropertyEvaluation::ComparableFinder, computes a weighted-median price/m² and
# hedonic adjustments via PropertyEvaluation::PriceEstimator, and returns a
# self-contained payload for serialization in evaluation_data JSONB.
#
# Flat result schema (no nested :data key):
#   { success: true, estimated_price:, min_price:, max_price:, price_per_sqm:,
#     base_price_per_sqm:, confidence_level: (0..1), tier:, comparables: [...],
#     adjustments: {...}, market_analysis: "...", recommendations: [...] }
#
# Failure: { success: false, error: "..." } — controller renders :new with flash.
class PropertyEvaluationService
  MIN_TIER1 = 8
  MIN_TIER2 = 4
  MIN_TIER3 = 3

  # Fallback ₽/м² when no comparables exist. Land is much cheaper per м² than buildings.
  ABSOLUTE_FALLBACK_PRICE_PER_SQM = {
    'apartment' => 250_000, 'house' => 180_000, 'land' => 5_000,
    'commercial' => 300_000, 'garage' => 80_000, 'room' => 200_000
  }.freeze

  def initialize(valuation)
    @v = valuation
  end

  def call
    return error('Недостаточно данных для оценки') unless valid?

    pool = PropertyEvaluation::ComparableFinder.new(@v).call

    if pool[:comparables].empty?
      return success(fallback_estimate)
    end

    base_estimate = PropertyEvaluation::PriceEstimator.new(@v, pool[:comparables]).call

    # Layer hedonic regression + bootstrap CI on top of the median estimate.
    # If sample is too thin (< 8) or regression degenerates, returns
    # base_estimate unchanged.
    estimate = PropertyEvaluation::CompositeEstimator.call(
      comparables: pool[:comparables],
      target_area: subject_area,
      target_rooms: @v.rooms.to_i,
      base_estimate: base_estimate
    )

    success(
      estimate.merge(
        confidence_level: confidence_for(pool, estimate),
        tier:             pool[:tier],
        comparables:      serialize(pool[:comparables].first(5)),
        market_analysis:  build_market_analysis(pool[:comparables], estimate),
        recommendations:  build_recommendations
      )
    )
  rescue StandardError => e
    Rails.logger.error("PropertyEvaluationService failure: #{e.class} #{e.message}\n" \
                       "#{e.backtrace.first(8).join("\n")}")
    error('Не удалось рассчитать оценку. Попробуйте позже.')
  end

  # Effective area for the algorithm: total_area for buildings,
  # land_area (converted сотки → м²) for land plots.
  def subject_area
    if @v.property_type.to_s == 'land'
      @v.respond_to?(:land_area_in_sqm) ? @v.land_area_in_sqm.to_f : @v.land_area.to_f * 100
    else
      @v.total_area.to_f
    end
  end

  private

  def valid?
    return false unless @v && @v.property_type.present? && @v.address.to_s.length >= 10
    subject_area.positive?
  end

  def confidence_for(pool, estimate = nil)
    base = case pool[:tier]
           when 1 then 0.85
           when 2 then 0.65
           when 3 then 0.45
           else 0.30
           end
    base += 0.05 if @v.building_year.present?
    base += 0.05 if @v.metro_station.present?
    # Hedonic regression with R²>0.5 — bumps confidence (model explains
    # majority of variance in our comparables).
    if estimate&.dig(:hedonic, :r_squared).to_f > 0.5
      base += 0.05
    end
    [base, 0.95].min.round(2)
  end

  def fallback_estimate
    pps = ABSOLUTE_FALLBACK_PRICE_PER_SQM[@v.property_type.to_s] || 200_000
    estimated = (pps * subject_area).round(-3)
    {
      estimated_price:    estimated,
      price_per_sqm:      pps,
      base_price_per_sqm: pps,
      min_price:          (estimated * 0.85).round(-3),
      max_price:          (estimated * 1.15).round(-3),
      confidence_level:   0.30,
      tier:               4,
      comparables:        [],
      adjustments:        {},
      market_analysis:    'Недостаточно сопоставимых объявлений в нашей базе для точной оценки. Мы используем средние региональные показатели.',
      recommendations:    build_recommendations
    }
  end

  def serialize(comps)
    comps.map do |c|
      r = c[:record]
      {
        title: r.try(:title) || compose_title(r),
        price: r.price,
        price_per_sqm: c[:price_per_sqm],
        area: r.area,
        rooms: r.rooms,
        district: r.district,
        distance_km: c[:distance_km]&.round(2),
        url: comparable_url(r),
        source: comparable_source(r)
      }
    end
  end

  def compose_title(r)
    [r.try(:rooms).present? ? "#{r.rooms}-комн." : nil,
     "#{r.area} м²",
     r.district.presence].compact.join(', ')
  end

  def comparable_url(r)
    return "/properties/#{r.to_param}" if r.is_a?(Property)
    r.try(:url)
  end

  def comparable_source(r)
    return 'agency' if r.is_a?(Property)
    'mls'
  end

  def build_market_analysis(comps, estimate)
    pieces = []
    pieces << "Найдено #{comps.size} сопоставимых объявлений в выбранном районе."
    pieces << "Средняя цена за м²: #{ActionController::Base.helpers.number_to_currency(estimate[:base_price_per_sqm], precision: 0)}."
    if estimate[:adjustments]&.any? { |_, c| c != 1.0 }
      pieces << 'Применены коэффициенты этажа, состояния, года постройки и удобств.'
    end
    pieces.join(' ')
  end

  def build_recommendations
    [
      { type: 'photography', priority: 'high',   title: 'Профессиональная фотосъёмка',
        description: 'Качественные фото увеличивают количество просмотров на 60%' },
      { type: 'documents',   priority: 'high',   title: 'Подготовьте документы заранее',
        description: 'Готовый пакет документов ускоряет сделку на 2-3 недели' },
      { type: 'marketing',   priority: 'medium', title: 'Комплексное продвижение',
        description: 'Размещение на топовых площадках + соцсети увеличит поток клиентов' }
    ]
  end

  def success(payload)
    { success: true }.merge(payload)
  end

  def error(message)
    { success: false, error: message }
  end
end
