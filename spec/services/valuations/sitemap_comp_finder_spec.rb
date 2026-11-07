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
