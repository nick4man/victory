# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Valuations::AiSyntheticComps do
  let(:valuation) do
    PropertyValuation.new(property_type: 'apartment', deal_type: 'sale',
                          audit_mode: 'express', total_area: 54, city: 'Рязань')
  end

  def build_comp(raw)
    described_class.new(valuation).send(:build_comp, raw)
  end

  it 'отклоняет отрицательные и нулевые ₽/м² (LLM-выбросы, PR #178)' do
    expect(build_comp(price_per_sqm: -1, area: 54)).to be_nil
    expect(build_comp(price_per_sqm: 0, area: 54)).to be_nil
  end

  it 'принимает положительные ₽/м²' do
    comp = build_comp(price_per_sqm: 100_000, area: 54, title: '2-комн. квартира')

    expect(comp).not_to be_nil
    expect(comp[:price_per_sqm]).to eq(100_000)
    expect(comp[:source]).to eq('ai_synthesized')
  end
end
