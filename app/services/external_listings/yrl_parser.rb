# frozen_string_literal: true

require 'nokogiri'
require 'open-uri'

module ExternalListings
  # Parses a Yandex Realty 2.0 XML feed (YRL) and upserts each <offer> into
  # the `external_listings` table. The schema is public — any agency that
  # syndicates to Я.Недвижимость publishes its catalog in this format, and
  # the URL is usually advertised in robots.txt or in Yandex.Webmaster's
  # feed registry. We treat the feeds as comparable data only — never
  # display third-party listings on our own catalog.
  #
  # Usage:
  #   ExternalListings::YrlParser.new('https://other-agency.ru/feed.xml').call
  #
  # Returns:
  #   { source: 'yandex_yrl', fetched: <int>, upserted: <int>, errors: [...] }
  class YrlParser
    SOURCE = 'yandex_yrl'

    # Yandex maps `<type>` + `<property-type>` to our schema. Yandex's
    # taxonomy is broader; we collapse to the same enum the rest of the
    # valuation pipeline uses (flat / room / house / land / commerce / garage).
    REALTY_TYPE_MAP = {
      ['жилая',     'квартира']  => 'flat',
      ['жилая',     'комната']   => 'room',
      ['жилая',     'дом']       => 'house',
      ['жилая',     'дом с участком'] => 'house',
      ['жилая',     'часть дома']     => 'house',
      ['земельный', nil]              => 'land',
      ['жилая',     'участок']        => 'land',
      ['коммерческая', nil]           => 'commerce',
      ['гараж',     nil]              => 'garage'
    }.freeze

    DEAL_TYPE_MAP = {
      'продажа' => 'sale',
      'аренда'  => 'rent'
    }.freeze

    def initialize(feed_url, source: SOURCE, http_timeout: 30)
      @feed_url = feed_url
      @source = source
      @http_timeout = http_timeout
    end

    def call
      xml = fetch_xml
      doc = Nokogiri::XML(xml) { |c| c.strict.nonet }
      # Yandex YRL declares `xmlns="…realty/2010-06"`; strip namespaces so we
      # can xpath `//offer` directly without juggling prefixed selectors.
      doc.remove_namespaces!

      offers = doc.xpath('//offer')
      fetched = offers.size
      upserted = 0
      errors = []

      offers.each do |offer|
        attrs = build_attrs(offer)
        next unless attrs && attrs[:source_id].present?

        upsert_one(attrs)
        upserted += 1
      rescue StandardError => e
        errors << "offer #{offer['internal-id']}: #{e.class} #{e.message.truncate(120)}"
      end

      { source: @source, fetched: fetched, upserted: upserted, errors: errors }
    rescue StandardError => e
      Rails.logger.error("[YrlParser] feed=#{@feed_url} failed: #{e.class} #{e.message}")
      { source: @source, fetched: 0, upserted: 0, errors: [e.message] }
    end

    private

    def fetch_xml
      uri = URI.parse(@feed_url)
      if uri.scheme.to_s.start_with?('http')
        URI.open(uri,
                 'User-Agent' => 'victory62-comp-bot/1.0',
                 read_timeout: @http_timeout).read
      elsif uri.scheme == 'file'
        File.read(uri.path)
      else
        # Bare local path
        File.read(@feed_url)
      end
    end

    # Pull the offer's interesting fields. Tags are Yandex-canonical
    # (kebab-case). We drop offers that miss the bare minimum (id + price
    # + area) — they can't serve as comparables.
    def build_attrs(offer)
      source_id = offer['internal-id'].presence || offer.at_xpath('./internal-id')&.text&.strip
      return nil if source_id.blank?

      type_attr   = text(offer, './type').to_s.downcase
      property_t  = text(offer, './property-type').to_s.downcase
      category    = text(offer, './category').to_s.downcase
      realty_type = REALTY_TYPE_MAP[[type_attr, property_t.presence]] ||
                    REALTY_TYPE_MAP[[type_attr, nil]] || infer_type_loose(type_attr, category)
      deal_type   = DEAL_TYPE_MAP[type_attr] || 'sale'

      price = numeric(text(offer, './price/value'))
      area  = numeric(text(offer, './area/value'))
      return nil if price.to_f.zero? || area.to_f.zero?

      {
        source:         @source,
        source_id:      source_id,
        url:            text(offer, './url'),
        title:          text(offer, './description')&.strip&.truncate(150),
        description:    text(offer, './description'),
        price:          price.to_i,
        area:           area,
        land_area:      numeric(text(offer, './lot-area/value')),
        rooms:          integer(text(offer, './rooms')),
        floor:          integer(text(offer, './floor')),
        total_floors:   integer(text(offer, './floors-total')),
        building_year:  integer(text(offer, './built-year')),
        condition:      text(offer, './renovation')&.downcase,
        district:       text(offer, './location/sub-locality-name'),
        address:        build_address(offer),
        latitude:       numeric(text(offer, './location/latitude')),
        longitude:      numeric(text(offer, './location/longitude')),
        property_type:  realty_type,
        deal_type:      deal_type,
        seller_kind:    text(offer, './sales-agent/category')&.downcase,
        seller_name:    text(offer, './sales-agent/organization'),
        seller_phone:   text(offer, './sales-agent/phone'),
        fetched_at:     Time.current,
        closed_at:      nil,
        raw_payload:    {
          internal_id:  source_id,
          last_modified: text(offer, './last-update-date')
        }
      }
    end

    def build_address(offer)
      parts = [
        text(offer, './location/region'),
        text(offer, './location/locality-name'),
        text(offer, './location/address'),
        text(offer, './location/sub-locality-name')
      ].compact_blank
      parts.join(', ')
    end

    def text(node, xpath)
      el = node.at_xpath(xpath)
      el&.text&.strip
    end

    def numeric(value)
      return nil if value.blank?

      Float(value.to_s.tr(',', '.'))
    rescue ArgumentError
      nil
    end

    def integer(value)
      n = numeric(value)
      n&.to_i
    end

    # Yandex sometimes uses just `<category>квартира</category>` without
    # the (type, property-type) tuple — fall back to keyword match.
    def infer_type_loose(_type_attr, category)
      case category.to_s.downcase
      when /квартир/      then 'flat'
      when /комнат/       then 'room'
      when /дом|коттедж/  then 'house'
      when /участ|земл/   then 'land'
      when /коммерц/      then 'commerce'
      when /гараж/        then 'garage'
      else nil
      end
    end

    def upsert_one(attrs)
      record = ExternalListing.find_or_initialize_by(source: attrs[:source], source_id: attrs[:source_id])
      record.assign_attributes(attrs)
      record.save(validate: false)
    end
  end
end
