# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Valuations::CrossCityAdapter do
  let(:valuation) do
    PropertyValuation.new(
      property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
      address: 'г. Санкт-Петербург, ул. Осипенко, д. 3', city: 'Санкт-Петербург',
      total_area: 26.6, rooms: 1, status: 'pending'
    )
  end

  let!(:flat_type) { PropertyType.create!(name: 'Квартира', slug: 'flat') }

  before do
    CityMedianPrice.create!(city: 'Санкт-Петербург', property_type: 'apartment',
                            median_price_per_sqm: 250_000)
    CityMedianPrice.create!(city: 'Москва', property_type: 'apartment',
                            median_price_per_sqm: 300_000)
  end

  def create_donor(deal_type)
    create(:property, :on_site,
           property_type: flat_type,
           deal_type: deal_type,
           address: 'Москва, ул. Тверская, д. 1',
           price: 7_980_000, area: 26.6)
  end

  it 'не подставляет rent-доноров в sale-оценку (issue #172)' do
    create_donor(:rent)

    expect(described_class.new(valuation).call).to be_empty
  end

  it 'подставляет sale-доноров с пересчётом по медиане города' do
    create_donor(:sale)

    comps = described_class.new(valuation).call

    expect(comps.size).to eq(1)
    expect(comps.first[:source]).to eq('cross_city_adapted')
    expect(comps.first[:donor_city]).to eq('Москва')
  end
end
