# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PropertyEvaluationService do
  # Subject: студия 26,6 м² в СПб (case #127/#126 из issue #172).
  let(:valuation) do
    PropertyValuation.new(
      property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
      address: 'г. Санкт-Петербург, ул. Осипенко, д. 3, кв. 1',
      city: 'Санкт-Петербург', total_area: 26.6, rooms: 1,
      latitude: 59.9398, longitude: 30.3146, status: 'pending'
    )
  end

  let(:pool) { [] }

  let(:filter_double) { instance_double(Valuations::AiCompFilter) }

  before do
    allow(Valuations::WebsearchCompFinder).to receive(:new)
      .and_return(instance_double(Valuations::WebsearchCompFinder, call: 0))
    allow(Valuations::SitemapCompFinder).to receive(:new)
      .and_return(instance_double(Valuations::SitemapCompFinder, call: 0))
    allow(Valuations::SemanticCompFinder).to receive(:call).and_return([])
    allow(Valuations::CrossCityAdapter).to receive(:call).and_return([])
    allow(Valuations::AiSyntheticComps).to receive(:call).and_return([])
    allow(Valuations::AiExplainer).to receive(:new)
      .and_return(instance_double(Valuations::AiExplainer, call: nil))
    # AI-фильтр пускает кандидатов как есть — нас здесь интересуют гейты
    # локальности и отсечение выбросов, а не LLM-фильтрация.
    allow(Valuations::AiCompFilter).to receive(:new) do |_v, candidates|
      allow(filter_double).to receive(:call).and_return(candidates)
      filter_double
    end
    allow(PropertyEvaluation::ComparableFinder).to receive(:new)
      .and_return(instance_double(PropertyEvaluation::ComparableFinder,
                                  call: { tier: 1, comparables: pool }))
    allow(PropertyEvaluation::CompositeEstimator).to receive(:call)
      .and_return({ base_price_per_sqm: 100_000, adjustments: {} })
  end

  def comp(source, pps, **extra)
    { source: source, price_per_sqm: pps, weight: 1.0, distance_km: 1.0,
      title: 'аналог', price: pps * 26, area: 26.6, rooms: 1 }.merge(extra)
  end

  describe 'отсечение выбросов ₽/м²' do
    # Различные title обязательны: base_pool делает .uniq по [source, title],
    # одинаковые заголовки схлопнут пул до одного компа и тест станет вакуумным.
    let(:pool) do
      [97_000, 98_000, 99_000, 100_000, 101_000, 102_000, 103_000, 510]
        .each_with_index.map { |pps, i| comp('external_listing', pps, title: "аналог-#{i}") }
    end

    it 'выброс не доходит до CompositeEstimator и сериализации' do
      received = nil
      allow(PropertyEvaluation::CompositeEstimator).to receive(:call) do |args|
        received = args[:comparables]
        { base_price_per_sqm: 100_000, adjustments: {} }
      end

      result = described_class.new(valuation).call

      expect(result[:success]).to be(true)
      expect(received.map { |c| c[:price_per_sqm] }).not_to include(510)
      expect(result[:comparables].map { |c| c[:price_per_sqm] }).not_to include(510)
    end

    it 'ai_filter считает пул ПОСЛЕ чистки выбросов (issue #201)' do
      result = described_class.new(valuation).call

      expect(result[:success]).to be(true)
      expect(result[:ai_filter][:candidates_raw]).to eq(8)
      expect(result[:ai_filter][:candidates_kept]).to eq(7) # без выброса 510 ₽/м²
      expect(result[:ai_filter][:candidates_rejected]).to eq(1)
    end

    it 'end-to-end: реальный CompositeEstimator/Hedonic не ломается выбросом' do
      # 8 локальных аналогов ~100 тыс. ₽/м² с разными rooms/area + аренда
      # 510 ₽/м². Без отсечения hedonic тянулся бы к выбросу (case #124).
      rooms_area = [[1, 40.0], [1, 35.0], [2, 54.0], [2, 60.0],
                    [2, 48.0], [3, 72.0], [3, 65.0], [2, 50.0]]
      local_comps = rooms_area.each_with_index.map do |(rooms, area), i|
        record = double('comp-record', id: i + 1, title: 'Квартира', price: 5_000_000,
                                      rooms: rooms, area: area, district: 'Центральный', url: nil)
        comp('external_listing', 96_000 + (i * 1_000), record: record, rooms: rooms, area: area)
      end
      outlier = comp('external_listing', 510,
                     record: double('outlier-record', id: 99, title: 'Аренда', price: 25_000,
                                                     rooms: 2, area: 54.0, district: 'Центральный', url: nil),
                     rooms: 2, area: 54.0)

      allow(PropertyEvaluation::CompositeEstimator).to receive(:call).and_call_original

      clean = call_with(local_comps)
      dirty = call_with(local_comps + [outlier])

      expect(clean[:success]).to be(true)
      expect(dirty[:success]).to be(true)
      expect(dirty[:estimated_price])
        .to be_within(clean[:estimated_price] * 0.15).of(clean[:estimated_price])
      expect(dirty[:estimated_price]).to be > 2_000_000
    end

    def call_with(comps)
      allow(PropertyEvaluation::ComparableFinder).to receive(:new)
        .and_return(instance_double(PropertyEvaluation::ComparableFinder,
                                    call: { tier: 1, comparables: comps }))
      described_class.new(valuation).call
    end
  end

  describe 'low_coverage' do
    it 'false, когда есть локальный аналог (agency)' do
      allow(PropertyEvaluation::ComparableFinder).to receive(:new)
        .and_return(instance_double(PropertyEvaluation::ComparableFinder,
                                    call: { tier: 1, comparables: [comp('agency', 100_000)] }))

      result = described_class.new(valuation).call

      expect(result[:success]).to be(true)
      expect(result[:low_coverage]).to be(false)
    end

    it 'true, когда остались только cross-city/AI аналоги' do
      allow(Valuations::CrossCityAdapter).to receive(:call)
        .and_return([comp('cross_city_adapted', 150_000)])

      result = described_class.new(valuation).call

      expect(result[:success]).to be(true)
      expect(result[:low_coverage]).to be(true)
    end

    it 'true при полностью пустой выборке (fallback)' do
      result = described_class.new(valuation).call

      expect(result[:success]).to be(true)
      expect(result[:tier]).to eq(4)
      expect(result[:low_coverage]).to be(true)
    end
  end

  describe 'полный пул аналогов в результате (ревью Kimi, PR #184)' do
    it 'внешний аналог не теряется при более чем пяти внутренних comps' do
      # Одинаковые ₽/м² и уникальные title: PriceEstimator не должен вычистить
      # пул как выбросы — тест детерминированно ловит старый first(5).
      internal = Array.new(6) { |i| comp('agency', 100_000, title: "аналог #{i}") }
      external = comp('external_listing', 100_000, title: 'внешний аналог',
                      url: 'https://ryazan.cian.ru/sale/flat/294573918/')
      allow(PropertyEvaluation::ComparableFinder).to receive(:new)
        .and_return(instance_double(PropertyEvaluation::ComparableFinder,
                                    call: { tier: 1, comparables: internal + [external] }))

      result = described_class.new(valuation, include_full_comparables: true).call

      expect(result[:success]).to be(true)
      # Публичный отчёт — компактно, как раньше (first(5))
      expect(result[:comparables].size).to eq(5)
      # Полный пул — только по флагу staff-тула (external-first там)
      expect(result[:full_comparables].size).to eq(7)
      urls = result[:full_comparables].map { |c| c[:url] }
      expect(urls).to include('https://ryazan.cian.ru/sale/flat/294573918/')
    end

    it 'по умолчанию full_comparables в ответе нет (публичные оценки не хранят пул)' do
      internal = Array.new(6) { |i| comp('agency', 100_000, title: "аналог #{i}") }
      external = comp('external_listing', 100_000, title: 'внешний аналог',
                      url: 'https://ryazan.cian.ru/sale/flat/294573918/')
      allow(PropertyEvaluation::ComparableFinder).to receive(:new)
        .and_return(instance_double(PropertyEvaluation::ComparableFinder,
                                    call: { tier: 1, comparables: internal + [external] }))

      result = described_class.new(valuation).call

      expect(result[:success]).to be(true)
      expect(result).not_to have_key(:full_comparables)
      expect(result[:comparables].size).to eq(5)
    end

    it 'пробрасывает фактический исход websearch-поиска (websearch_count)' do
      allow(Valuations::WebsearchCompFinder).to receive(:new)
        .and_return(instance_double(Valuations::WebsearchCompFinder, call: 4))

      result = described_class.new(valuation).call

      expect(result[:success]).to be(true)
      expect(result[:websearch_count]).to eq(4)
    end
  end
end
