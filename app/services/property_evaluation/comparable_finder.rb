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

    # Жёсткий потолок расстояния для аналогов: comp дальше 50 км от subject
    # (при известных координатах обеих сторон) не считается локальным.
    # Раньше предела не было — в выборку попадали объекты за 100-200 км
    # и размывали взвешенную медиану (issue #172).
    MAX_RADIUS_KM = 50

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
                         .area_band(external_band_area, tier.area_pct)
                         .rooms_band(@v.rooms.to_i, tier.rooms_delta)
      # ExternalListing хранит город источника (issue #172): для
      # subject с известным городом чужие города отсекаем на уровне SQL.
      # NULL city (legacy avito/cian из websearch) в выборку не попадают —
      # происхождение неизвестно, доверять ему для чужого города нельзя.
      # LOWER() — чтобы совпадали и 'Рязань', и 'рязань' (нормализация
      # регистра в writers не трогает уже сохранённые данные).
      subject_city = normalized_subject_city
      s = s.where('LOWER(city) = ?', subject_city.downcase) if subject_city.present?
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

    # ±30% площади subject — hard size pre-filter ДО любого AI judgement.
    # Subject 100 м² → captures 70-130 м² comps. Студии 30 м² и
    # 5-комн 250 м² отсеиваются. Это responsibility split: objective
    # size sanity here, subjective fit (район, segment, condition) —
    # in AiCompFilter.
    #
    # Не применяется к land (площадь в сотках, broader range OK для
    # участков с разной целевой застройкой).
    SIZE_BAND_PCT = 0.30

    def enrich(records)
      target_area = subject_area_for_filter
      band_min = target_area.positive? ? target_area * (1 - SIZE_BAND_PCT) : 0
      band_max = target_area.positive? ? target_area * (1 + SIZE_BAND_PCT) : Float::INFINITY
      apply_size_filter = target_area.positive? && @v.property_type.to_s != 'land'

      records.filter_map do |r|
        pps = compute_pps(r)
        next nil if pps <= 0
        dist = distance_km_to(r)
        # Город и радиус — hard gates ДО взвешивания: сюда попадают comps
        # из property/mls scopes, где apply_geo на tier 3/4 может пропустить
        # чужой город/дальний объект (issue #172).
        next nil unless same_city?(r, dist)
        next nil if dist && dist > MAX_RADIUS_KM

        if apply_size_filter
          area = r.try(:area).to_f
          area = r.try(:total_area).to_f if area.zero? && r.respond_to?(:total_area)
          next nil unless area.between?(band_min, band_max)
        end

        { record: r, price_per_sqm: pps, distance_km: dist,
          weight: dist ? 1.0 / (1.0 + dist) : 0.5,
          source: source_label(r) }.tap do |comp|
          # Land-объявления площадок хранят площадь в сотках, а estimator
          # нормализован к ₽/м² (subject_area участка = land_area × 100).
          # Без перевода comp смешивал бы ₽/сотку с ₽/м² и цена участка
          # искажалась на порядки (ревью Kimi, PR #184).
          if @v.property_type.to_s == 'land' && r.is_a?(ExternalListing)
            area_sqm = r.area.to_f * 100
            comp[:area] = area_sqm
            comp[:price_per_sqm] = (r.price.to_f / area_sqm).round if area_sqm.positive?
          end
        end
      end.sort_by { |c| c[:distance_km] || Float::INFINITY }
    end

    # Площадь subject в ЕДИНИЦАХ ХРАНЕНИЯ источника: ExternalListing хранит
    # land-площади в сотках (парсер площадок), каталог/MLS — в м². Band
    # должен быть в тех же единицах, что area записей источника.
    def external_band_area
      @v.property_type.to_s == 'land' ? @v.land_area.to_f : @v.total_area.to_f
    end

    # Город subject vs город comp'а. Fail-close в обе стороны:
    # - пустой город subject — локальность подтверждает только расстояние
    #   ≤ MAX_RADIUS_KM; без координат у любой из сторон comp не локален
    #   (websearch-записи без координат иначе проходили по кругу через
    #   guess_city → Рязань, issue #172, правки по ревью Kimi);
    # - пустой город comp'а — то же правило;
    # - оба города известны — case-insensitive совпадение.
    def same_city?(record, distance_km = nil)
      subject_city = normalized_subject_city
      return distance_km.present? && distance_km <= MAX_RADIUS_KM if subject_city.blank?

      record_city = ExternalListing.normalize_city(record.city)
      return distance_km.present? && distance_km <= MAX_RADIUS_KM if record_city.blank?

      record_city.casecmp?(subject_city)
    end

    def normalized_subject_city
      @normalized_subject_city ||= ExternalListing.normalize_city(@v.city)
    end

    # Label источника по record class. Используется downstream'ом
    # для (1) sources_breakdown analytics, (2) auto_kept logic в
    # PropertyEvaluationService — ExternalListing comps уже vetted
    # через Tavily whitelist + Sonnet sanity checks → bypass AiCompFilter.
    def source_label(record)
      case record
      when ExternalListing then 'external_listing'
      when MlsListing      then 'mls'
      when Property        then 'agency'
      else                      record.class.name.underscore
      end
    end

    def subject_area_for_filter
      if @v.property_type.to_s == 'land'
        @v.try(:land_area).to_f * 100  # сотки → м²
      else
        @v.total_area.to_f
      end
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
