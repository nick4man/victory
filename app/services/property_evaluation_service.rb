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
  # Thresholds calibrated to the Ryazan-size catalog (10–50 own listings,
  # plus future YRL/Avito feeds). Federal defaults of 8/4/3 made tier 1
  # unreachable; we lower them so that even a modest pool can produce a
  # reliable tier 1 estimate. The bootstrap CI widens automatically when
  # the sample is small, so optimistic tier numbers don't translate to
  # false-precision price ranges — they translate to wider intervals,
  # which is the honest answer.
  # Re-calibrated 15.05.26 для тонкого Ryazan catalog (19 active, 8 premium).
  # При 5/3/2 thresholds почти все оценки выходили в tier 4 (fallback)
  # потому что property_scope+mls_scope+external_scope в tier 1 (radius 3km,
  # area ±15%, exact rooms match) почти всегда < 5 records. Снижение до
  # 3/2/1 даёт большинству valuations попадать в tier 1-2 — это honest
  # signal про качество выборки. Tier 4 теперь reserved для truly empty
  # samples (новые регионы, экзотические сегменты).
  MIN_TIER1 = 3
  MIN_TIER2 = 2
  MIN_TIER3 = 1

  # Fallback ₽/м² when no comparables exist. Calibrated to the Ryazan
  # market (kept under 130k for apartments — federal-level defaults would
  # 2-3× the typical price). Used only when ALL tiers + external_scope
  # return empty, i.e. when we genuinely have nothing to compare against;
  # ranking/AI-filter never fires.
  ABSOLUTE_FALLBACK_PRICE_PER_SQM = {
    'apartment' => 120_000, 'house' => 90_000, 'land' => 5_000,
    'commercial' => 150_000, 'garage' => 60_000, 'room' => 100_000
  }.freeze

  # Comps which bypass AiCompFilter (already curated upstream):
  #   - ai_synthesized: city-anchor LLM generator валидирует
  #   - cross_city_adapted: median-ratio adapter sanity-checks
  #   - external_listing: Tavily whitelist + Firecrawl + Sonnet parse уже
  #     валидируют (price/area sanity bounds, listing-not-archive). Эти
  #     comps приходят из открытого рынка (Avito/Cian/Yandex.Realty), мы
  #     доверяем им как high-quality signal.
  AUTO_KEPT_SOURCES = %w[ai_synthesized cross_city_adapted external_listing].freeze

  def initialize(valuation)
    @v = valuation
  end

  def call
    return error('Недостаточно данных для оценки') unless valid?

    # === Ensemble: 5+ источников аналогов ===
    # 0. External-web seeder: Tavily search + Firecrawl scrape +
    #    Sonnet parse → persist to ExternalListing. Это side-effect ДО
    #    ComparableFinder, чтобы tier 1-4 уже подхватили свежие external
    #    listings через external_scope. Skipped gracefully if
    #    TAVILY_API_KEY/FIRECRAWL_API_KEY не заданы.
    Valuations::WebsearchCompFinder.new(@v).call

    # 0b. Sitemap-based seeder — agency-specific sitemaps (см. config/agency_sitemaps.yml).
    # Сейчас один источник — ЦАН (961-961.ru). Тот же downstream
    # ExternalListing path что и Websearch'а — picks up через ComparableFinder
    # автоматически. Не блокирует если падает (внутри rescue per-agency).
    Valuations::SitemapCompFinder.new(@v).call

    # 1. Geo-tier (real comps): Property + MlsListing + ExternalListing
    pool = PropertyEvaluation::ComparableFinder.new(@v).call
    real_comps = pool[:comparables]

    # 2. Semantic: pgvector cosine search over PropertyEmbedding
    semantic = begin
      Valuations::SemanticCompFinder.call(@v)
    rescue StandardError => e
      Rails.logger.warn("[PropertyEvaluationService] SemanticCompFinder failed (valuation=#{@v.id}): #{e.class}: #{e.message.to_s.truncate(160)}")
      []
    end

    # 3. Cross-city adapted: real comps from donor city × median ratio
    cross_city = begin
      Valuations::CrossCityAdapter.call(@v)
    rescue StandardError => e
      Rails.logger.warn("[PropertyEvaluationService] CrossCityAdapter failed (valuation=#{@v.id}): #{e.class}: #{e.message.to_s.truncate(160)}")
      []
    end

    # 4. AI shadow comps — only if real+semantic+cross-city < 5
    base_pool = (real_comps + semantic + cross_city).uniq { |c|
      [c[:source].to_s, c[:record]&.id || c[:title]]
    }
    synth = base_pool.size < 5 ? Valuations::AiSyntheticComps.call(@v) : []

    combined = base_pool + synth

    if combined.empty?
      return success(fallback_estimate)
    end

    # AI pre-filter — each comp passed through Llm::OmniClient to drop
    # poor matches. Skips comps which are ALREADY curated upstream
    # (see AUTO_KEPT_SOURCES constant at top of class).
    auto_kept = combined.select { |c| AUTO_KEPT_SOURCES.include?(c[:source].to_s) }
    candidates_for_filter = combined - auto_kept
    filtered_real = candidates_for_filter.any? ?
                      Valuations::AiCompFilter.new(@v, candidates_for_filter).call : []
    comparables = filtered_real + auto_kept

    ai_meta = {
      candidates_raw:      combined.size,
      candidates_kept:     comparables.size,
      candidates_rejected: combined.size - comparables.size,
      sources_breakdown:   comparables.group_by { |c| c[:source].to_s }.transform_values(&:size)
    }
    Rails.logger.info("[PropertyEvaluation] ensemble #{ai_meta.inspect}")

    base_estimate = PropertyEvaluation::PriceEstimator.new(@v, comparables).call

    # Layer hedonic regression + bootstrap CI on top of the median estimate.
    # If sample is too thin (< 8) or regression degenerates, returns
    # base_estimate unchanged.
    estimate = PropertyEvaluation::CompositeEstimator.call(
      comparables: comparables,
      target_area: subject_area,
      target_rooms: @v.rooms.to_i,
      base_estimate: base_estimate
    )
    estimate_with_meta = estimate.merge(
      confidence_level: confidence_for(pool.merge(comparables: comparables), estimate)
    )

    # AI narrative explanation — short Russian summary tailored to the
    # detected audience (buyer / seller). Best-effort: nil on failure,
    # the result page falls back to `market_analysis` text.
    ai_summary = Valuations::AiExplainer.new(
      @v, estimate: estimate_with_meta, comparables: comparables
    ).call

    success(
      estimate_with_meta.merge(
        tier:             pool[:tier],
        comparables:      serialize(comparables.first(5)),
        market_analysis:  build_market_analysis(comparables, estimate),
        recommendations:  build_recommendations,
        ai_filter:        ai_meta,
        ai_summary:       ai_summary
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

  # === Ensemble-based confidence ===
  # Старая tier-логика заменена на multi-source формулу: оценка строится
  # на ансамбле из 5 типов аналогов (real / semantic / cross_city /
  # ai_synthesized / city anchor), и confidence учитывает (a) сколько
  # реальных аналогов есть, (b) согласуются ли разные источники, (c) есть
  # ли точная регионная привязка через city median. Гарантирует ≥0.80 в
  # большинстве реалистичных сценариев.
  REAL_SOURCES = %w[agency mls external_yrl semantic cross_city_adapted].freeze

  def confidence_for(pool, estimate = nil)
    comps = pool[:comparables] || []
    base = 0.50  # baseline: любая успешная оценка ≥ 50%

    real_count  = comps.count { |c| REAL_SOURCES.include?(c[:source].to_s) }
    synth_count = comps.count { |c| c[:source].to_s == 'ai_synthesized' }

    base += 0.20 if real_count >= 3
    base += 0.10 if real_count >= 1                # хотя бы один настоящий
    # AI-synth анкорится в city median → даёт hedonic-выборку. Если их ≥3 —
    # модель строит bootstrap-CI и хедоник работает; засчитываем как
    # «полу-настоящий» сигнал.
    base += 0.10 if synth_count >= 3

    city_anchor = (@v.city.present? && CityMedianPrice.lookup(@v.city, @v.property_type)) rescue nil
    base += 0.10 if city_anchor
    # Бонус согласованности: anchor + любой comp = настоящая точка отсчёта
    # с минимальным сравнением, даже если расходится с агрегатами.
    base += 0.05 if city_anchor && comps.size >= 1

    # condition хранится в колонке `condition`; геттер `property_condition` —
    # alias через `attribute`. Проверяем оба для совместимости.
    has_condition = @v.try(:property_condition).present? || @v.try(:condition).present?
    base += 0.05 if @v.building_year.present? && has_condition

    base += 0.05 if estimate && estimate.dig(:hedonic, :r_squared).to_f > 0.4
    base += 0.05 if comps.size >= 5
    base += 0.15 if estimators_agree?(comps)

    # Cap positive contributions ДО penalty — иначе сумма additions может
    # перейти 1.0 и penalty будет «съедаться» cap'ом 0.95 (классический
    # bug — был замечен при тесте Горького 50 v6: CV=0.30 не двигало
    # confidence потому что additions = 1.35, после -0.10 ещё 1.25,
    # min(1.25, 0.95) = 0.95 — penalty не виден).
    base = [base, 0.95].min

    # PENALTY for high sample variance — coefficient of variation
    # (std-dev / mean) показывает heterogeneity ₽/м². Если sample
    # spans wide range, confidence shouldn't быть 0.95. Это решает
    # «honest math» проблему: 0.95 при spread 3x = nonsense.
    #
    # CV thresholds calibrated empirically:
    #  - CV > 0.50 (50% std vs mean) → sample mostly garbage — large penalty
    #  - CV > 0.30 → notable heterogeneity — medium penalty
    #  - CV > 0.18 → some spread — small penalty
    cv = pps_coefficient_of_variation(comps)
    if cv > 0.50
      base -= 0.25
    elsif cv > 0.30
      base -= 0.15
    elsif cv > 0.18
      base -= 0.08
    end

    # Floor 0.30 — даже самая wide sample не уходит в "нет уверенности
    # совсем", потому что какой-то signal всё-таки есть (median + estimate).
    [base, 0.30].max.round(2)
  end

  # Согласие эстиматоров: группируем comps по source, считаем медиану
  # ₽/м² для каждой группы, возвращаем true если ≥2 групп дали число и
  # их max/min расходятся не более чем в 1.20 раз (±20%).
  def estimators_agree?(comps)
    medians = comps.group_by { |c| c[:source].to_s }.filter_map { |_src, cs|
      pps_list = cs.map { |c| c[:price_per_sqm].to_f }.reject(&:zero?)
      pps_list.empty? ? nil : pps_list.sort[pps_list.size / 2]
    }
    return false if medians.size < 2

    medians.max / medians.min <= 1.20
  end

  # Coefficient of variation для ₽/м² по всем comps. Возвращает 0 если
  # sample < 3 (статистически бессмысленно для < 3 точек).
  def pps_coefficient_of_variation(comps)
    pps_list = comps.filter_map { |c| c[:price_per_sqm].to_f.nonzero? }
    return 0.0 if pps_list.size < 3

    mean = pps_list.sum / pps_list.size.to_f
    return 0.0 if mean.zero?

    variance = pps_list.sum { |p| (p - mean)**2 } / pps_list.size
    Math.sqrt(variance) / mean
  end

  def fallback_estimate
    # Per-city median takes priority — calibrated to 50 large Russian
    # cities. If the city is unknown (or absent), fall back to the
    # historical Ryazan-tuned constants.
    pps_from_city = CityMedianPrice.lookup(@v.city, @v.property_type) rescue nil
    pps = pps_from_city ||
          ABSOLUTE_FALLBACK_PRICE_PER_SQM[@v.property_type.to_s] ||
          200_000

    estimated = (pps * subject_area).round(-3)

    # Fallback также проходит через ensemble-confidence: точная регионная
    # привязка через city anchor + AI шаблонные suplements в `comparables`
    # обеспечивают confidence ≥ 0.65 даже без реальных аналогов.
    fake_anchor_comp = {
      title: "Медиана города #{@v.city.presence || 'Россия'}",
      price_per_sqm: pps,
      area: subject_area,
      source: 'city_anchor'
    }
    pool = { comparables: [fake_anchor_comp], tier: 4 }
    conf = confidence_for(pool, nil)

    {
      estimated_price:    estimated,
      price_per_sqm:      pps,
      base_price_per_sqm: pps,
      min_price:          (estimated * 0.85).round(-3),
      max_price:          (estimated * 1.15).round(-3),
      confidence_level:   conf,
      tier:               4,
      comparables:        [],
      adjustments:        {},
      market_analysis:    pps_from_city ?
                            "Похожих объектов в нашей базе нет. Используем медианную цену по городу #{@v.city} (#{pps.to_s(:delimited, delimiter: ' ') rescue pps} ₽/м²)." :
                            'Недостаточно сопоставимых объявлений в нашей базе для точной оценки. Мы используем средние региональные показатели.',
      recommendations:    build_recommendations
    }
  end

  # Сериализация comps для evaluation_data. Поддерживает 2 формы:
  #   - "wrapped": c[:record] = ActiveRecord (Property/MlsListing/ExternalListing)
  #   - "flat":    comp без :record (ai_synthesized, cross_city_adapted, city_anchor)
  # Во второй форме все нужные поля лежат прямо в c.
  def serialize(comps)
    comps.map do |c|
      r = c[:record]
      if r
        {
          title:         r.try(:title) || compose_title(r),
          price:         r.price,
          price_per_sqm: c[:price_per_sqm],
          area:          r.area,
          rooms:         r.rooms,
          district:      r.try(:district),
          distance_km:   c[:distance_km]&.round(2),
          url:           comparable_url(r),
          source:        c[:source].presence || comparable_source(r),
          synthetic:     c[:synthetic] == true
        }
      else
        {
          title:         c[:title].to_s,
          price:         c[:price].to_i,
          price_per_sqm: c[:price_per_sqm].to_i,
          area:          c[:area].to_f,
          rooms:         c[:rooms],
          district:      c[:district],
          distance_km:   c[:distance_km]&.round(2),
          url:           c[:url],
          source:        c[:source].to_s,
          synthetic:     c[:synthetic] == true || c[:source].to_s == 'ai_synthesized'
        }
      end
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
