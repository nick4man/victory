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

    it 'отбрасывает объект каталога без города и без координат (fail-close)' do
      # Локальность не подтверждена ни городом, ни расстоянием — такой аналог
      # не должен попадать в выборку и скрывать low_coverage (issue #172).
      property = create(:property, :on_site, property_type_id: flat_type.id,
                                             deal_type: :sale, area: 54, rooms: 2)
      property.update_columns(city: nil, district: 'Канищево',
                              latitude: nil, longitude: nil)

      result = described_class.new(
        build_valuation(city: 'Рязань', coords: [nil, nil], district: 'Канищево')
      ).call

      expect(result[:comparables].map { |c| c[:record] }).not_to include(property)
    end

    it 'оставляет объект каталога без города, но в радиусе 50 км' do
      property = create_catalog_property(nil, [54.63, 39.72])

      result = described_class.new(
        build_valuation(city: 'Рязань', coords: [54.6292, 39.7187])
      ).call

      expect(result[:comparables].map { |c| c[:record] }).to include(property)
    end

    it 'принимает объект по расстоянию, если город subject неизвестен' do
      property = create_catalog_property('Казань', [55.79, 49.12])

      result = described_class.new(
        build_valuation(city: nil, coords: [55.7887, 49.1221])
      ).call

      expect(result[:comparables].map { |c| c[:record] }).to include(property)
    end

    it 'отбрасывает объект без расстояния при неизвестном городе subject (fail-close)' do
      # Websearch-записи без координат и без города не считаются локальными:
      # иначе guess_city → Рязань пускал бы чужие города по кругу (issue #172).
      listing = create(:external_listing, :agency_sitemap,
                       property_type: 'flat', deal_type: 'sale',
                       area: 54, rooms: 2, city: nil)

      result = described_class.new(
        build_valuation(city: nil, coords: [nil, nil])
      ).call

      expect(result[:comparables].map { |c| c[:record] }).not_to include(listing)
    end
  end

  describe 'регистр города' do
    it 'находит external_listing с городом в другом регистре' do
      create_ryazan_sitemap_listings(2, city: 'рЯзанЬ')

      result = described_class.new(
        build_valuation(city: 'Рязань', coords: [54.6292, 39.7187], district: 'Канищево')
      ).call

      expect(result[:comparables].size).to eq(2)
    end

    it 'нормализует префикс «г.» у города external_listing при записи' do
      listing = create(:external_listing, :agency_sitemap,
                       property_type: 'flat', deal_type: 'sale',
                       area: 54, rooms: 2, district: 'Канищево', city: 'г. Рязань')

      expect(listing.reload.city).to eq('Рязань')

      result = described_class.new(
        build_valuation(city: 'Рязань', coords: [54.6292, 39.7187], district: 'Канищево')
      ).call

      expect(result[:comparables].map { |c| c[:record] }).to include(listing)
    end
  end

  # Ревью Kimi (PR #184, раунд 4): каталог хранит land-площади в м²,
  # объявления площадок — в сотках. Без нормализации comp-домена медиана
  # смешивала ₽/м² с ₽/соткой и цена участка искажалась на порядки.
  describe 'land: единая нормализация пула к ₽/м²' do
    let!(:land_type) { PropertyType.create!(name: 'Земля', slug: 'land') }

    def build_land_valuation
      PropertyValuation.new(
        property_type: 'land', deal_type: 'sale', audit_mode: 'express',
        address: 'г. Рязань, Канищево', city: 'Рязань', district: 'Канищево',
        land_area: 8, total_area: 800, status: 'pending'
      )
    end

    it 'смешанный пул (каталог м² + площадка сотки) даёт одинаковый ₽/м²' do
      catalog = create(:property, :on_site, property_type_id: land_type.id,
                                            deal_type: :sale, area: 800, rooms: 0,
                                            district: 'Канищево', city: 'Рязань',
                                            price: 1_800_000)
      listing = create(:external_listing, source: 'cian',
                                          url: 'https://ryazan.cian.ru/sale/land/888/',
                                          property_type: 'land', deal_type: 'sale',
                                          city: 'Рязань', district: 'Канищево',
                                          area: 8.0, rooms: 0, price: 1_800_000,
                                          fetched_at: Time.current, closed_at: nil)

      result = described_class.new(build_land_valuation).call

      comps = result[:comparables]
      expect(comps.map { |c| c[:record] }).to contain_exactly(catalog, listing)
      expect(comps.map { |c| c[:price_per_sqm] }.uniq).to eq([2250])
      listing_comp = comps.find { |c| c[:record] == listing }
      expect(listing_comp[:area]).to eq(800.0) # сотки → м²
    end

    # Ревью Kimi (PR #184, раунд 5): YRL хранит дом в м² (area) и участок
    # отдельно в land_area (сотки), websearch — сотки прямо в area. Без
    # source-aware нормализации YRL-аналог получал ₽/м², заниженный в 100 раз.
    it 'YRL-аналог (area м² дома + land_area сотки) даёт тот же ₽/м², что websearch' do
      yrl = create(:external_listing, source: 'yandex_yrl', source_id: 'yrl-land-1',
                                    url: 'https://realty.yandex.ru/offer/land-1/',
                                    property_type: 'land', deal_type: 'sale',
                                    city: 'Рязань', district: 'Канищево',
                                    area: 150.0, land_area: 8.0, rooms: 0,
                                    price: 1_800_000,
                                    fetched_at: Time.current, closed_at: nil)
      websearch_like = create(:external_listing, source: 'cian', source_id: 'cian-land-1',
                                                 url: 'https://ryazan.cian.ru/sale/land/999/',
                                                 property_type: 'land', deal_type: 'sale',
                                                 city: 'Рязань', district: 'Канищево',
                                                 area: 8.0, rooms: 0, price: 1_800_000,
                                                 fetched_at: Time.current, closed_at: nil)

      result = described_class.new(build_land_valuation).call

      comps = result[:comparables]
      expect(comps.map { |c| c[:record] }).to include(yrl, websearch_like)
      expect(comps.map { |c| c[:price_per_sqm] }.uniq).to eq([2250])
      expect(comps.map { |c| c[:area] }.uniq).to eq([800.0])
    end
  end
end
