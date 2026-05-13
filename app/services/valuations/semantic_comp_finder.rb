# frozen_string_literal: true

module Valuations
  # Finds Property comparables via semantic similarity (gemini-embedding-001
  # vectors + cosine distance through pgvector + neighbor gem) rather than
  # geo/area tiers. Useful when:
  #
  #   - the subject city has few/no geo-near comps (тонкий каталог),
  #   - the subject is a rare segment (премиум / коммерция / IZH-участок),
  #
  # Algorithm:
  #   1. Build a short Russian text "summary" of the subject (similar in
  #      shape to Embedding::PropertyTextTemplate#build but works on a
  #      PropertyValuation).
  #   2. Embed via Embedding::GoogleClient (same provider used for the
  #      rest of the embedding pipeline).
  #   3. Query `PropertyEmbedding.nearest_neighbors(:embedding, vec, ...)`
  #      → top 20 closest; filter out comps with cosine < MIN_COSINE.
  #   4. Map to the standard comp-hash shape used by PropertyEvaluation.
  class SemanticCompFinder
    LIMIT       = 20
    MIN_COSINE  = 0.75   # below this — different segments, not useful
    SOURCE_TAG  = 'semantic'

    def self.call(valuation)
      new(valuation).call
    end

    def initialize(valuation)
      @v = valuation
    end

    def call
      text = build_subject_text
      return [] if text.blank?

      vector = embed_text(text)
      return [] unless vector.is_a?(Array) && vector.length > 100

      embeddings = PropertyEmbedding
                     .nearest_neighbors(:embedding, vector, distance: :cosine)
                     .includes(:property)
                     .limit(LIMIT)
                     .to_a

      embeddings.filter_map { |emb| build_comp(emb) }
    rescue StandardError => e
      Rails.logger.warn("[Valuations::SemanticCompFinder] #{e.class}: #{e.message.truncate(180)}")
      []
    end

    private

    def build_subject_text
      bits = []
      bits << property_type_label
      bits << ("#{@v.rooms}-комн" if @v.rooms.to_i.positive?)
      bits << ("#{@v.total_area} м²" if @v.total_area.to_f.positive?)
      bits << ("этаж #{@v.floor}/#{@v.total_floors}" if @v.floor && @v.total_floors)
      bits << ("район #{@v.district}" if @v.district.present?)
      bits << ("город #{@v.city}" if @v.city.present?)
      bits << ("год постройки #{@v.building_year}" if @v.building_year.present?)
      bits << condition_label
      bits.compact.reject(&:empty?).join(', ')
    end

    def property_type_label
      {
        'apartment'  => 'Квартира',
        'room'       => 'Комната',
        'house'      => 'Дом',
        'land'       => 'Земельный участок',
        'commercial' => 'Коммерческая недвижимость',
        'garage'     => 'Гараж'
      }[@v.property_type.to_s]
    end

    def condition_label
      {
        'needs_repair' => 'требует ремонта',
        'average'      => 'жилое состояние',
        'good'         => 'с ремонтом',
        'excellent'    => 'евроремонт',
        'designer'     => 'дизайнерский ремонт'
      }[@v.property_condition.to_s] || @v.property_condition.presence
    end

    def embed_text(text)
      Embedding::GoogleClient.new.embed(text)
    end

    def build_comp(embedding_row)
      property = embedding_row.property
      return nil unless property && property.price.to_i.positive? && property.area.to_f.positive?

      cos = if embedding_row.respond_to?(:neighbor_distance) && embedding_row.neighbor_distance
              1.0 - embedding_row.neighbor_distance.to_f
            else
              nil
            end
      return nil if cos && cos < MIN_COSINE

      pps = (property.price.to_f / property.area.to_f).round
      distance_km = distance_km_to(property)

      {
        title:           property.title.to_s.truncate(80),
        price:           property.price.to_i,
        price_per_sqm:   pps,
        area:            property.area.to_f,
        rooms:           property.rooms,
        district:        property.district,
        distance_km:     distance_km,
        url:             property.respond_to?(:slug) ? "/properties/#{property.slug}" : nil,
        source:          SOURCE_TAG,
        cosine:          cos&.round(3),
        record:          property,
        weight:          weight_for(cos, distance_km)
      }
    end

    def distance_km_to(property)
      return nil unless @v.latitude && @v.longitude && property.latitude && property.longitude

      Geocoder::Calculations.distance_between(
        [@v.latitude, @v.longitude],
        [property.latitude, property.longitude],
        units: :km
      )
    rescue StandardError
      nil
    end

    # Weight in the final weighted-median: high cosine + close geo → 0.6;
    # high cosine but far → 0.4; weak match → 0.2.
    def weight_for(cos, distance_km)
      base = cos ? (cos - MIN_COSINE) / (1.0 - MIN_COSINE) : 0.5  # 0..1 within MIN_COSINE..1
      base = base.clamp(0.0, 1.0) * 0.5 + 0.1
      base += 0.1 if distance_km && distance_km < 25
      base.round(2)
    end
  end
end
