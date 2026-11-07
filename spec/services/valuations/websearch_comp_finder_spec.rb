# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Valuations::WebsearchCompFinder do
  let(:valuation) do
    PropertyValuation.new(
      property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
      address: 'г. Санкт-Петербург, ул. Осипенко, д. 3',
      city: 'Санкт-Петербург', district: 'Красногвардейский',
      total_area: 26.6, rooms: 1, status: 'pending'
    )
  end

  let(:finder) { described_class.new(valuation) }

  def parsed(city: 'Санкт-Петербург', url: 'https://cian.ru/offer/123456')
    {
      source_url: url,
      title: 'Студия, 26,6 м²',
      price: 5_400_000,
      area: 26.6,
      rooms: 1,
      floor: 11,
      total_floors: 17,
      building_year: 2005,
      condition: 'good',
      district: 'Красногвардейский',
      address: 'ул. Осипенко, д. 3',
      city: city
    }
  end

  describe '#persist — атрибуция города' do
    it 'сохраняет город, подтверждённый карточкой' do
      finder.send(:persist, [parsed])

      record = ExternalListing.find_by!(source: 'cian', source_id: '123456')
      expect(record.city).to eq('Санкт-Петербург')
    end

    it 'отклоняет объявление из чужого города, даже если subject его запрашивал' do
      count = finder.send(:persist, [parsed(city: 'Рязань')])

      expect(count).to eq(0)
      expect(ExternalListing.where(source_id: '123456')).not_to exist
    end

    it 'не перезаписывает подтверждённый город существующей записи городом subject' do
      create(:external_listing, source: 'cian', source_id: '123456', city: 'Рязань')

      count = finder.send(:persist, [parsed(city: '')])

      expect(count).to eq(1)
      expect(ExternalListing.find_by!(source: 'cian', source_id: '123456').city).to eq('Рязань')
    end

    it 'приписывает новой записи город subject, если карточка город не подтверждает' do
      count = finder.send(:persist, [parsed(city: '')])

      expect(count).to eq(1)
      expect(ExternalListing.find_by!(source: 'cian', source_id: '123456').city).to eq('Санкт-Петербург')
    end

    it 'нормализует префикс «г.» у города из карточки' do
      finder.send(:persist, [parsed(city: 'г. Санкт-Петербург')])

      expect(ExternalListing.find_by!(source: 'cian', source_id: '123456').city)
        .to eq('Санкт-Петербург')
    end
  end
end
