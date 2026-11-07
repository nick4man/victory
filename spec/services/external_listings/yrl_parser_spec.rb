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
end
