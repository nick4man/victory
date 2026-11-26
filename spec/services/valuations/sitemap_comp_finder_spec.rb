# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Valuations::SitemapCompFinder do
  def build_valuation(city, deal_type: 'sale')
    PropertyValuation.new(
      property_type: 'apartment', deal_type: deal_type, audit_mode: 'express',
      address: "г. #{city}, ул. Тестовая, д. 1", city: city,
      total_area: 54, rooms: 2, status: 'pending'
    )
  end

  before do
    # WebMock::NetConnectNotAllowedError наследует Exception и потому пробивает
    # rescue StandardError внутри fetch_xml — даём пустой 200 чтобы дошло до ''.
    stub_request(:get, 'https://961-961.ru/sitemap.xml').to_return(status: 200, body: '')
  end

  it 'не ходит в сеть для оценок вне города агентства (СПб, Москва)' do
    allow(Net::HTTP).to receive(:start).and_call_original

    result = described_class.new(build_valuation('Санкт-Петербург')).call

    expect(result).to eq(0)
    expect(Net::HTTP).not_to have_received(:start)
  end

  it 'запускает discovery для оценок в городе агентства (Рязань)' do
    allow(Net::HTTP).to receive(:start).and_call_original

    described_class.new(build_valuation('Рязань')).call

    expect(Net::HTTP).to have_received(:start).with('961-961.ru', 443, any_args)
  end

  it 'запускает discovery и при неизвестном городе subject (критерий — только «точно вне города»)' do
    allow(Net::HTTP).to receive(:start).and_call_original

    described_class.new(build_valuation(nil)).call

    expect(Net::HTTP).to have_received(:start).with('961-961.ru', 443, any_args)
  end

  it 'не запускает pipeline для rent-оценок: парсер ищет только продажу (issue #172)' do
    allow(Net::HTTP).to receive(:start).and_call_original

    result = described_class.new(build_valuation('Рязань', deal_type: 'rent')).call

    expect(result).to eq(0)
    expect(Net::HTTP).not_to have_received(:start)
  end

  describe '#cached_count — source-aware band для участков (ревью Kimi, PR #184)' do
    def build_land_valuation
      PropertyValuation.new(
        property_type: 'land', deal_type: 'sale', audit_mode: 'express',
        address: 'г. Рязань, Канищево', city: 'Рязань', district: 'Канищево',
        total_area: 800, land_area: 8, rooms: 0, status: 'pending'
      )
    end

    it 'участок: cache hit по effective соткам (COALESCE land_area/area)' do
      # sitemap-запись: сотки в area — попадает через area
      create(:external_listing, source: 'agency_sitemap', source_id: '961:1',
                               property_type: 'land', deal_type: 'sale',
                               area: 8.0, rooms: 0, price: 1_800_000,
                               fetched_at: Time.current, closed_at: nil)
      # YRL-стиль: дом в м² в area + участок в сотках в land_area — через land_area
      create(:external_listing, source: 'agency_sitemap', source_id: '961:2',
                               property_type: 'land', deal_type: 'sale',
                               area: 150.0, land_area: 8.0, rooms: 0, price: 1_800_000,
                               fetched_at: Time.current, closed_at: nil)
      # Другой agency_key — source_id prefix-gate, не попадает
      create(:external_listing, source: 'agency_sitemap', source_id: 'other:1',
                               property_type: 'land', deal_type: 'sale',
                               area: 8.0, rooms: 0, price: 1_800_000,
                               fetched_at: Time.current, closed_at: nil)
      # Вне band 6.0–10.0 соток
      create(:external_listing, source: 'agency_sitemap', source_id: '961:3',
                               property_type: 'land', deal_type: 'sale',
                               area: 30.0, rooms: 0, price: 5_000_000,
                               fetched_at: Time.current, closed_at: nil)

      expect(described_class.new(build_land_valuation).send(:cached_count, '961')).to eq(2)
    end
  end

  describe '#persist (private)' do
    it 'проставляет город агентства в city записи' do
      finder = described_class.new(build_valuation('Рязань'))

      expect do
        finder.send(:persist, [{ source_url: 'https://961-961.ru/catalog/158515/',
                                 title: '2-комн. квартира', price: 5_400_000,
                                 area: 54, rooms: 2 }], 'cian_961')
      end.to change(ExternalListing, :count).by(1)

      expect(ExternalListing.last.city).to eq('Рязань')
    end
  end
end
