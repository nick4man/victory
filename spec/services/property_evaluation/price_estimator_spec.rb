# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PropertyEvaluation::PriceEstimator do
  let(:valuation) do
    PropertyValuation.new(property_type: 'apartment', deal_type: 'sale',
                          audit_mode: 'express', total_area: 54)
  end

  def comp(price_per_sqm, weight = 1.0)
    { price_per_sqm: price_per_sqm, weight: weight }
  end

  it 'отбрасывает выброс по ₽/м² (аренда 510 среди продаж ~100 тыс.) до взвешенной медианы' do
    comps = [comp(96_000), comp(98_000), comp(100_000), comp(102_000), comp(104_000), comp(510)]

    result = described_class.new(valuation, comps).call

    expect(result[:base_price_per_sqm]).to eq(100_000)
    expect(result[:estimated_price]).to eq(5_400_000)
  end

  it 'не трогает выборку, где разброс в пределах фактора выброса' do
    comps = [comp(100_000), comp(150_000), comp(200_000)]

    result = described_class.new(valuation, comps).call

    expect(result[:base_price_per_sqm]).to eq(150_000)
  end

  it 'не фильтрует малую выборку (< 3 аналогов)' do
    comps = [comp(100_000), comp(140_000)]

    result = described_class.new(valuation, comps).call

    expect(result[:base_price_per_sqm]).to eq(100_000)
  end

  it 'возвращает очищенный пул без выброса для downstream-расчётов' do
    comps = [comp(96_000), comp(98_000), comp(100_000), comp(102_000), comp(104_000), comp(510)]

    result = described_class.new(valuation, comps).call

    expect(result[:comparables].map { |c| c[:price_per_sqm] }).not_to include(510)
    expect(result[:comparables].size).to eq(5)
  end

  it 'выбрасывает неположительные ₽/м² из пула и медианы (LLM-выбросы, PR #177)' do
    comps = [comp(-50_000), comp(0), comp(96_000), comp(100_000), comp(104_000)]

    result = described_class.new(valuation, comps).call

    expect(result[:base_price_per_sqm]).to eq(100_000)
    expect(result[:estimated_price]).to be_positive
    expect(result[:comparables].map { |c| c[:price_per_sqm] }).to all(be_positive)
  end

  it 'не даёт отрицательной оценки, когда все аналоги с неположительными ₽/м²' do
    result = described_class.new(valuation, [comp(-10), comp(0)]).call

    expect(result[:base_price_per_sqm]).to eq(0)
    expect(result[:estimated_price]).to eq(0)
  end
end
