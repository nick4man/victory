# frozen_string_literal: true

module Valuations
  # Часть 3 (issue #176): semantic-поиск похожих ЗАВЕРШЁННЫХ оценок
  # сотрудников через property_valuation_embeddings (cosine, pgvector)
  # для ориентира цены в чат-боте сайта.
  #
  # Отличия от SemanticCompFinder (который ищет объекты каталога):
  #   • корпус — PropertyValuationEmbedding, а не PropertyEmbedding;
  #   • фильтр по городу и типу сделки ЖЁСТКИЙ (правило #172): оценка
  #     другого города или аренда не попадают, даже при высоком cosine;
  #   • fail-close по городу: у subject пустой город → 0 результатов,
  #     а не агрегат по чужому рынку;
  #   • staff_test-оценки исключены уже на этапе эмбеддинга (issue #201),
  #     здесь — страховочный фильтр;
  #   • корпус ограничен оценками СОТРУДНИКОВ: клиентские express-оценки
  #     (сайт, чат-бот) тоже попадают в embeddings (#175), но бот не должен
  #     называть их «оценками наших специалистов» — фильтр по
  #     metadata['source'] == 'work_bot' (контракт ключа см. в
  #     ChatTools::Staff::MarketComparables#valuation_metadata);
  #   • в SQL до LIMIT уходят жёсткие фильтры (source/deal_type/status/self),
  #     а фильтр по городу остаётся в Ruby (нормализация «г.»/регистр —
  #     ExternalListing.normalize_city). Поэтому LIMIT берёт увеличенный пул
  #     CANDIDATE_LIMIT кандидатов, а не 20 финальных: иначе 20 ближайших
  #     оценок другого города вытеснят подходящие и дадут ложный
  #     low_coverage (блокер ревью #206).
  #
  # Возвращает ТОЛЬКО агрегат — поштучные адреса/цены/телефоны чужих
  # оценок наружу не отдаём:
  #   { count:, median_price:, min_price:, max_price:, low_coverage: }
  # low_coverage = count < MIN_COUNT (3) — чат честно говорит «данных
  # мало» и фолбэкается на экспресс-оценку.
  #
  # При любой инфраструктурной ошибке (нет API key, сеть, БД) → nil:
  # вызывающий код молча деградирует до express-only ответа.
  class SimilarValuationsFinder
    # Пул кандидатов до Ruby-фильтра по городу/cosine — см. шапку класса.
    CANDIDATE_LIMIT = 100
    MIN_COSINE = 0.75   # как у SemanticCompFinder — ниже это другой сегмент
    MIN_COUNT  = 3      # меньше — low_coverage, агрегат не показываем
    # Контракт ключа — ChatTools::Staff::MarketComparables#valuation_metadata
    STAFF_SOURCE = 'work_bot'

    def self.call(valuation)
      new(valuation).call
    end

    def initialize(valuation)
      @v = valuation
    end

    def call
      subject_city = ExternalListing.normalize_city(@v.city)
      return zero_result if subject_city.blank?

      text = Embedding::PropertyValuationTextTemplate.build(@v)
      return zero_result if text.blank?

      vector = Embedding::GoogleClient.new.embed(text)
      return zero_result unless vector.is_a?(Array) && vector.length > 100

      rows = PropertyValuationEmbedding
             .nearest_neighbors(:embedding, vector, distance: :cosine)
             .joins(:property_valuation)
             .includes(:property_valuation)
             .where(property_valuations: { deal_type: @v.deal_type, status: 'completed' })
             .where("property_valuations.metadata ->> 'source' = ?", STAFF_SOURCE)
             .where.not(property_valuation_id: @v.id)
             .limit(CANDIDATE_LIMIT)

      prices = rows.filter_map { |row| price_for(row, subject_city) }
      aggregate(prices)
    rescue StandardError => e
      Rails.logger.warn("[Valuations::SimilarValuationsFinder] #{e.class}: #{e.message.to_s.truncate(180)}")
      nil
    end

    private

    def price_for(row, subject_city)
      valuation = row.property_valuation
      return nil unless valuation && valuation.completed? && !valuation.staff_test?
      # Страховочный дубль SQL-фильтра (строка выше) — fail-close.
      return nil unless valuation.metadata.is_a?(Hash) && valuation.metadata['source'] == STAFF_SOURCE
      return nil if valuation.id == @v.id
      return nil if valuation.audit_mode_investment?
      # Правило #172: тот же город и тот же тип сделки — жёстко.
      return nil unless valuation.deal_type.to_s == @v.deal_type.to_s

      other_city = ExternalListing.normalize_city(valuation.city)
      return nil unless other_city&.casecmp?(subject_city)

      cos = 1.0 - row.neighbor_distance.to_f if row.respond_to?(:neighbor_distance) && row.neighbor_distance
      return nil if cos && cos < MIN_COSINE

      price = valuation.estimated_price.to_i
      price.positive? ? price : nil
    end

    def aggregate(prices)
      sorted = prices.sort
      n = sorted.size
      median = if n.zero?
                 nil
               elsif n.odd?
                 sorted[n / 2]
               else
                 ((sorted[n / 2 - 1] + sorted[n / 2]) / 2.0).round
               end
      {
        count:        n,
        median_price: median,
        min_price:    sorted.first,
        max_price:    sorted.last,
        low_coverage: n < MIN_COUNT
      }
    end

    def zero_result
      aggregate([])
    end
  end
end
