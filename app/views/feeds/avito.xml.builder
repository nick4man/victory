# frozen_string_literal: true

# Avito Autoload feed.
# Spec: https://www.avito.ru/autoload/documentation/templates
#
# Notes:
# - Root element: <Ads formatVersion="3" target="Avito.ru">. Avito has
#   broken backwards compat on root attributes in the past — formatVersion=3
#   is the current stable.
# - <Images> uses ATTRIBUTE-style URLs: <Image url="..."/>. This is the one
#   field that trips most engineers writing their first Avito feed.
# - Each ad needs <Id>, <Category>, <OperationType>, <Address>, <Title>,
#   <Description>, <Price>, <ContactPhone> — the rest are category-specific
#   and skipped when nil.
# - Apartment-specific fields (<Rooms>, <Floor>, <Floors>, <Square>,
#   <HouseType>, <BalconyOrLoggia>) only emit when the resolved property
#   type is flat/room — they're invalid on land/garage listings.

xml.instruct! :xml, version: '1.0', encoding: 'UTF-8'
xml.Ads(formatVersion: '3', target: 'Avito.ru') do
  @properties.each do |property|
    ad = AvitoFeedMapper.new(property, host: @host).to_h
    next if ad.nil?
    next if ad[:title].blank? || ad[:address].blank? || ad[:price].nil? || ad[:price].zero?

    is_apartment_like = %w[flat room].include?(ad[:property_type_slug])
    is_building_like  = %w[flat room house commerce].include?(ad[:property_type_slug])

    xml.Ad do
      xml.Id              ad[:id]
      xml.DateBegin       ad[:date_begin]
      xml.ListingFee      ad[:listing_fee]
      xml.AdStatus        ad[:ad_status]

      xml.Category        ad[:category]
      xml.OperationType   ad[:operation_type]
      xml.PropertyRights  ad[:property_rights] if ad[:property_rights]

      xml.ManagerName     ad[:manager_name]
      xml.ContactPhone    ad[:contact_phone]

      xml.Address         ad[:address]
      xml.Latitude        ad[:latitude]  if ad[:latitude]
      xml.Longitude       ad[:longitude] if ad[:longitude]

      xml.Title           ad[:title]
      xml.Description     { xml.cdata!(ad[:description]) } if ad[:description]
      xml.Price           ad[:price]

      xml.Square          ad[:square] if ad[:square]

      if is_apartment_like
        xml.Rooms           ad[:rooms]         if ad[:rooms]
        xml.LivingSpace     ad[:living_space]  if ad[:living_space]
        xml.KitchenSpace    ad[:kitchen_space] if ad[:kitchen_space]
        xml.Floor           ad[:floor]         if ad[:floor]
        xml.BalconyOrLoggia ad[:balcony_or_loggia] if ad[:balcony_or_loggia]
      end

      if is_building_like
        xml.Floors      ad[:floors]      if ad[:floors]
        xml.HouseType   ad[:house_type]  if ad[:house_type]
        xml.BuiltYear   ad[:built_year]  if ad[:built_year]
      end

      if ad[:images].any?
        xml.Images do
          ad[:images].each { |url| xml.Image(url: url) }
        end
      end
    end
  end
end
