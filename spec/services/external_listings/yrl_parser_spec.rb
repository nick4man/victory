# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalListings::YrlParser do
  # Минимальный валидный YRL 2.0 с двумя offer'ами в Рязани.
  let(:feed_xml) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <realty-feed xmlns="http://webmaster.yandex.ru/schemas/feed/realty/2010-06">
        <offer internal-id="172-test-1">
          <type>продажа</type>
          <property-type>квартира</property-type>
          <category>квартира</category>
          <price><value>5400000</value></price>
          <area><value>54</value></area>
          <rooms>2</rooms>
          <location>
            <country>Россия</country>
            <region>Рязанская область</region>
            <locality-name>Рязань</locality-name>
            <sub-locality-name>Канищево</sub-locality-name>
            <address>ул. Тестовая, д. 1</address>
            <latitude>54.6292</latitude>
            <longitude>39.7187</longitude>
          </location>
        </offer>
      </realty-feed>
    XML
  end

  def parse_feed
    file = Tempfile.new(%w[feed .xml])
    file.write(feed_xml)
    file.flush
    described_class.new(file.path).call
  ensure
    file.close!
  end

  it 'сохраняет город из locality-name при каждом upsert' do
    result = parse_feed

    expect(result[:upserted]).to eq(1)
    expect(ExternalListing.find_by!(source: 'yandex_yrl', source_id: '172-test-1').city)
      .to eq('Рязань')
  end

  it 'запись парсера доступна ComparableFinder для рязанской оценки (parser → finder)' do
    parse_feed

    valuation = PropertyValuation.new(
      property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
      address: 'г. Рязань, ул. Тестовая, д. 1', city: 'Рязань',
      district: 'Канищево', total_area: 54, rooms: 2, status: 'pending',
      latitude: 54.6292, longitude: 39.7187
    )

    result = PropertyEvaluation::ComparableFinder.new(valuation).call

    expect(result[:comparables].map { |c| c[:record] })
      .to include(ExternalListing.find_by!(source: 'yandex_yrl', source_id: '172-test-1'))
  end

  it 'запись парсера не попадает в выборку для оценки чужого города' do
    parse_feed

    valuation = PropertyValuation.new(
      property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
      address: 'г. Санкт-Петербург, ул. Осипенко, д. 3', city: 'Санкт-Петербург',
      total_area: 54, rooms: 2, status: 'pending',
      latitude: 59.9398, longitude: 30.3146
    )

    result = PropertyEvaluation::ComparableFinder.new(valuation).call

    expect(result[:comparables]).to be_empty
  end

  # Ревью Kimi (PR #184, раунд 7): <lot-area> несёт unit, парсер его
  # игнорировал — кв. м попадали в land_area как сотки. Контракт
  # ExternalListing.land_area — сотки; иначе band-фильтр терял запись,
  # а ₽/м² искажался в 100 раз. Проверяем обе единицы end-to-end:
  # парсер → запись → ComparableFinder.
  describe 'нормализация <lot-area> к соткам' do
    def parse_land_feed(lot_area_xml)
      file = Tempfile.new(%w[feed .xml])
      file.write(<<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <realty-feed xmlns="http://webmaster.yandex.ru/schemas/feed/realty/2010-06">
          <offer internal-id="land-1">
            <type>продажа</type>
            <property-type>участок</property-type>
            <category>участок</category>
            <price><value>1800000</value></price>
            <area><value>150</value></area>
            <lot-area>#{lot_area_xml}</lot-area>
            <location>
              <country>Россия</country>
              <region>Рязанская область</region>
              <locality-name>Рязань</locality-name>
              <sub-locality-name>Канищево</sub-locality-name>
              <address>ул. Тестовая, д. 1</address>
              <latitude>54.6292</latitude>
              <longitude>39.7187</longitude>
            </location>
          </offer>
        </realty-feed>
      XML
      file.flush
      described_class.new(file.path).call
    ensure
      file.close!
    end

    def land_comparables
      valuation = PropertyValuation.new(
        property_type: 'land', deal_type: 'sale', audit_mode: 'express',
        address: 'г. Рязань, Канищево, ул. Тестовая, д. 1', city: 'Рязань',
        district: 'Канищево', total_area: 800, land_area: 8, rooms: 0,
        status: 'pending', latitude: 54.6292, longitude: 39.7187
      )

      PropertyEvaluation::ComparableFinder.new(valuation).call[:comparables]
    end

    it 'кв. м переводится в сотки и запись проходит в band участка 8 соток' do
      parse_land_feed('<value>800</value><unit>кв. м</unit>')

      record = ExternalListing.find_by!(source: 'yandex_yrl', source_id: 'land-1')
      expect(record.land_area).to eq(8.0)

      comp = land_comparables.find { |c| c[:record] == record }
      expect(comp).to be_present
      # ₽/м² по нормализованной площади: 1.8M / 800 м², а не 1.8M / 80 000 м²
      expect(comp[:price_per_sqm]).to eq(2250)
    end

    it 'сотки сохраняются как есть (регрессия прежнего поведения)' do
      parse_land_feed('<value>8</value><unit>сотка</unit>')

      record = ExternalListing.find_by!(source: 'yandex_yrl', source_id: 'land-1')
      expect(record.land_area).to eq(8.0)
      expect(land_comparables.map { |c| c[:record] }).to include(record)
    end

    it 'unit опущен — дефолт YRL «сотка»' do
      parse_land_feed('<value>8</value>')

      expect(ExternalListing.find_by!(source: 'yandex_yrl', source_id: 'land-1').land_area)
        .to eq(8.0)
    end
  end
end
