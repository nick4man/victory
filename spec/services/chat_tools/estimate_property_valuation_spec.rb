# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::EstimatePropertyValuation do
  let(:service_result) do
    {
      success: true,
      estimated_price: 5_400_000,
      min_price: 4_968_000,
      max_price: 5_832_000,
      price_per_sqm: 100_000,
      confidence_level: 0.65,
      tier: 4,
      comparables: [],
      ai_summary: '',
      low_coverage: true
    }
  end

  before do
    allow(PropertyEvaluationService).to receive(:new).and_return(double(call: service_result))
    allow(Geocoding::AddressLookup).to receive(:call).and_return(nil)
  end

  def call_tool
    described_class.call(
      'property_type' => 'apartment',
      'address' => 'г. Рязань, ул. Тестовая, д. 1',
      'city' => 'Рязань',
      'total_area' => 54
    )
  end

  it 'прокидывает признак low_coverage из сервиса оценки' do
    expect(call_tool[:low_coverage]).to be(true)
  end

  it 'передаёт low_coverage: false когда локальные аналоги есть' do
    service_result[:low_coverage] = false

    expect(call_tool[:low_coverage]).to be(false)
  end

  it 'при завершении через update_columns ставит EmbedPropertyValuationJob явно' do
    expect { call_tool }.to have_enqueued_job(EmbedPropertyValuationJob)
  end

  describe '.schema' do
    it 'объясняет боту, как озвучивать низкое покрытие' do
      description = described_class.schema.dig(:function, :description)

      expect(description).to include('low_coverage')
      expect(description).to match(/ориентировочн/i)
    end
  end
end
