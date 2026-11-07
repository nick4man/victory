# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PropertyEvaluation::ComparableFinder do
  # Координаты: Рязань ~54.6292/39.7187, Москва 55.7558/37.6173,
  # СПб 59.9398/30.3146. 1° широты ≈ 111 км.

  def build_valuation(city:, coords:, district: nil)
    PropertyValuation.new(
      property_type: 'apartment',
      deal_type: 'sale',
      audit_mode: 'express',
      address: "г. #{city}, ул. Тестовая, д. 1",
      city: city,
      district: district,
      total_area: 54,
      rooms: 2,
      latitude: coords.first,
      longitude: coords.last,
      status: 'pending'
    )
  end

  def create_ryazan_sitemap_listings(count, **overrides)
    create_list(
      :external_listing, count, :agency_sitemap,
      { property_type: 'flat', deal_type: 'sale',
        area: 54, rooms: 2, district: 'Канищево' }.merge(overrides)
    )
  end

  describe 'фильтр по городу для external_listing' do
    it 'не берёт рязанские объявления 961-961.ru для оценки в Санкт-Петербурге' do
      create_ryazan_sitemap_listings(3)

      result = described_class.new(
        build_valuation(city: 'Санкт-Петербург', coords: [59.9398, 30.3146],
                        district: 'Красногвардейский')
      ).call

      expect(result[:comparables]).to be_empty
    end

    it 'берёт рязанские объявления для рязанской оценки' do
      create_ryazan_sitemap_listings(3, city: 'Рязань')

      result = described_class.new(
        build_valuation(city: 'Рязань', coords: [54.6292, 39.7187], district: 'Канищево')
      ).call

      expect(result[:comparables].size).to eq(3)
    end
  end

  describe 'потолок расстояния' do
    let!(:flat_type) { PropertyType.create!(name: 'Квартира', slug: 'flat') }

    def create_catalog_property(city, coords)
      property = create(:property, :on_site, property_type_id: flat_type.id,
                                             deal_type: :sale, area: 54, rooms: 2)
      property.update_columns(city: city, latitude: coords.first, longitude: coords.last)
      property
    end

    it 'отбрасывает объект каталога дальше 50 км даже при совпадении города' do
      # «Москва» на 111 км севернее центра Москвы — city совпадает, расстояние нет
      create_catalog_property('Москва', [56.7558, 37.6173])

      result = described_class.new(
        build_valuation(city: 'Москва', coords: [55.7558, 37.6173])
      ).call

      expect(result[:comparables]).to be_empty
    end

    it 'оставляет объект каталога в радиусе 3 км (tier 1)' do
      property = create_catalog_property('Москва', [55.76, 37.6173])

      result = described_class.new(
        build_valuation(city: 'Москва', coords: [55.7558, 37.6173])
      ).call

      expect(result[:comparables].map { |c| c[:record] }).to include(property)
    end
  end
end
