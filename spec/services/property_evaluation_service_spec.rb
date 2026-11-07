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
    let(:pool) do
      [comp('external_listing', 97_000), comp('external_listing', 98_000),
       comp('external_listing', 99_000), comp('external_listing', 100_000),
       comp('external_listing', 101_000), comp('external_listing', 102_000),
       comp('external_listing', 103_000), comp('external_listing', 510)]
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
end
