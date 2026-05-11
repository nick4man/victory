# frozen_string_literal: true

# ЦИАН feed — XSD documentation at https://www.cian.ru/help/exchange/feeds/
#
# Notes:
# - Root element is <feed> with <feed_version>2</feed_version> child.
# - Each property is <object>. Fields use PascalCase (vs YRL's kebab-case).
# - Empty elements like <FloorNumber></FloorNumber> trip CIAN's validator,
#   so each field is rendered only when its mapper value is non-nil.
# - Offers whose category can't be resolved (e.g. unknown property_type)
#   are skipped — CianFeedMapper#to_h returns nil for them.

xml.instruct! :xml, version: '1.0', encoding: 'UTF-8'
xml.feed do
  xml.feed_version 2

  @properties.each do |property|
    offer = CianFeedMapper.new(property, host: @host).to_h
    next if offer.nil?
    next if offer[:bargain_terms].nil? || offer[:address].blank?

    xml.object do
      xml.ExternalId      offer[:external_id]
      xml.Category        offer[:category]
      xml.Address         offer[:address]
      xml.Url             offer[:url] if offer[:url]
      xml.Description     { xml.cdata!(offer[:description]) } if offer[:description]
      xml.LastUpdateDate  offer[:last_update_date]

      if (coords = offer[:coordinates])
        xml.Coordinates do
          xml.Lat coords[:lat]
          xml.Lng coords[:lng]
        end
      end

      if offer[:phones].any?
        xml.Phones do
          offer[:phones].each do |phone|
            xml.PhoneSchema do
              xml.CountryCode phone[:country_code]
              xml.Number      phone[:number]
            end
          end
        end
      end

      if offer[:photos].any?
        xml.Photos do
          offer[:photos].each do |photo|
            xml.PhotoSchema do
              xml.FullUrl   photo[:full_url]
              xml.IsDefault photo[:is_default]
            end
          end
        end
      end

      if (bt = offer[:bargain_terms])
        xml.BargainTerms do
          xml.Price            bt[:price]
          xml.Currency         bt[:currency]
          xml.PriceType        bt[:price_type] if bt[:price_type]
          xml.MortgageAllowed  bt[:mortgage_allowed] unless bt[:mortgage_allowed].nil?
          xml.LeasePeriod      bt[:lease_period] if bt[:lease_period]
        end
      end

      xml.TotalArea     offer[:total_area]    if offer[:total_area]
      xml.LivingArea    offer[:living_area]   if offer[:living_area]
      xml.KitchenArea   offer[:kitchen_area]  if offer[:kitchen_area]
      xml.RoomsCount    offer[:rooms_count]   if offer[:rooms_count]
      xml.FloorNumber   offer[:floor_number]  if offer[:floor_number]
      xml.Decoration    offer[:decoration]    if offer[:decoration]
      xml.HasLoggia     offer[:has_loggia]    unless offer[:has_loggia].nil?
      xml.HasBalcony    offer[:has_balcony]   unless offer[:has_balcony].nil?

      if (bld = offer[:building])
        xml.Building do
          xml.FloorsCount  bld[:floors_count]  if bld[:floors_count]
          xml.BuildYear    bld[:build_year]    if bld[:build_year]
          xml.MaterialType bld[:material_type] if bld[:material_type]
          xml.PassengerLiftsCount bld[:passenger_lifts_count] if bld[:passenger_lifts_count]
        end
      end

      if (land = offer[:land])
        xml.Land do
          xml.Area          land[:area]
          xml.AreaUnitType  land[:area_unit_type]
        end
      end
    end
  end
end
