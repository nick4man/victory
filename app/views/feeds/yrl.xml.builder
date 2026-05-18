# frozen_string_literal: true

# Yandex Realty (YRL) feed — emitted per Property in @properties via
# PropertyFeedMapper. Schema spec:
# https://yandex.ru/support/realty-partner/ru/
#
# Empty / nil values are skipped (the spec marks most fields optional, and
# Yandex's import validator rejects empty tags like <floor></floor>).
#
# Namespace: webmaster.yandex.ru/schemas/feed/realty/2010-06 (НЕ feed.yandex.ru
# и НЕ schema без s). 18.05.26 — Я.Webmaster XML-validator rejected feed
# with old `feed.yandex.ru/schema/feed/realty/2010-06` namespace ("Не удалось
# найти объявление элемента 'realty-feed'" / "неверное пространство имён").
# Confirmed current namespace через partner ecosystem (Bitrix/CMS plugins).

xml.instruct! :xml, version: '1.0', encoding: 'UTF-8'
xml.tag!('realty-feed', xmlns: 'http://webmaster.yandex.ru/schemas/feed/realty/2010-06') do
  xml.tag!('generation-date', Time.current.iso8601)

  @properties.each do |property|
    offer = PropertyFeedMapper.new(property, host: @host).to_h
    next if offer[:price].nil? || offer[:area].nil?

    xml.offer('internal-id' => offer[:internal_id]) do
      xml.type             offer[:type]
      xml.tag!('property-type', offer[:property_type])
      xml.category         offer[:category]
      xml.url              offer[:url]
      xml.tag!('creation-date',    offer[:creation_date])
      xml.tag!('last-update-date', offer[:last_update_date])

      if (loc = offer[:location])
        xml.location do
          xml.country         loc[:country]
          xml.region          loc[:region]
          xml.tag!('locality-name',     loc[:locality])
          xml.tag!('sub-locality-name', loc[:sub_locality]) if loc[:sub_locality]
          xml.address         loc[:address] if loc[:address]
          xml.latitude        loc[:latitude]  if loc[:latitude]
          xml.longitude       loc[:longitude] if loc[:longitude]
        end
      end

      if (agent = offer[:sales_agent])
        xml.tag!('sales-agent') do
          xml.name         agent[:name]
          xml.phone        agent[:phone]
          xml.category     agent[:category]
          xml.organization agent[:organization]
          xml.url          agent[:url]
          xml.email        agent[:email] if agent[:email]
        end
      end

      if (price = offer[:price])
        xml.price do
          xml.value    price[:value]
          xml.currency price[:currency]
          xml.period   price[:period] if price[:period]
        end
      end

      if (area = offer[:area])
        xml.area do
          xml.value area[:value]
          xml.unit  area[:unit]
        end
      end

      if (living = offer[:living_space])
        xml.tag!('living-space') do
          xml.value living[:value]
          xml.unit  living[:unit]
        end
      end

      if (kitchen = offer[:kitchen_space])
        xml.tag!('kitchen-space') do
          xml.value kitchen[:value]
          xml.unit  kitchen[:unit]
        end
      end

      xml.rooms          offer[:rooms]         if offer[:rooms]
      xml.floor          offer[:floor]         if offer[:floor]
      xml.tag!('floors-total', offer[:floors_total]) if offer[:floors_total]
      xml.tag!('built-year',   offer[:built_year])   if offer[:built_year]
      xml.tag!('building-type', offer[:building_type]) if offer[:building_type]
      xml.renovation     offer[:renovation]    if offer[:renovation]
      xml.balcony        offer[:balcony]       if offer[:balcony]
      xml.description    { xml.cdata!(offer[:description]) } if offer[:description]

      offer[:images].to_a.each do |img_url|
        xml.image img_url
      end
    end
  end
end
