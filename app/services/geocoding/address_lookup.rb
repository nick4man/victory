# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

# Address → coordinates lookup with two providers tried in order:
#   1. DaData (cleaner.dadata.ru) — best for Russian addresses, free 10k/day
#   2. Yandex Geocoder (geocode-maps.yandex.ru) — fallback
#
# Returns Geocoding::AddressLookup::Result or nil. Never raises.
# All network errors / missing keys / rate-limit responses are logged and yield nil
# so that calling code can degrade gracefully (district-level matching).
module Geocoding
  class AddressLookup
    Result = Struct.new(
      :latitude, :longitude, :formatted_address, :city, :district, :provider,
      keyword_init: true
    )

    DADATA_URL = 'https://cleaner.dadata.ru/api/v1/clean/address'
    YANDEX_URL = 'https://geocode-maps.yandex.ru/1.x/'

    def self.call(address)
      new(address).call
    end

    def initialize(address)
      @address = address.to_s.strip
    end

    def call
      return nil if @address.empty?

      try_dadata || try_yandex
    end

    private

    def try_dadata
      token = ENV['DADATA_API_KEY'].to_s
      secret = ENV['DADATA_SECRET_KEY'].presence || ENV['DADATA_SECRET'].to_s
      return nil if token.empty? || secret.empty?

      uri = URI(DADATA_URL)
      req = Net::HTTP::Post.new(uri)
      req['Authorization'] = "Token #{token}"
      req['X-Secret'] = secret
      req['Content-Type'] = 'application/json'
      req['Accept'] = 'application/json'
      req.body = JSON.generate([@address])

      res = perform(uri, req)
      return nil unless res.is_a?(Net::HTTPSuccess)

      data = JSON.parse(res.body).first
      return nil unless data.is_a?(Hash)
      return nil if data['geo_lat'].to_s.empty? || data['geo_lon'].to_s.empty?

      Result.new(
        latitude: data['geo_lat'].to_f,
        longitude: data['geo_lon'].to_f,
        formatted_address: data['result'],
        city: data['city'].presence || data['region'],
        district: data['city_district'].presence || data['settlement'].presence || data['area'],
        provider: 'dadata'
      )
    rescue StandardError => e
      Rails.logger.warn("[Geocoding] DaData failed for #{@address.inspect}: #{e.class} #{e.message}")
      nil
    end

    def try_yandex
      key = ENV['YANDEX_GEOCODER_API_KEY'].to_s
      return nil if key.empty?

      uri = URI(YANDEX_URL)
      uri.query = URI.encode_www_form(
        apikey: key, geocode: @address, format: 'json',
        results: 1, lang: 'ru_RU'
      )
      res = perform(uri, Net::HTTP::Get.new(uri))
      return nil unless res.is_a?(Net::HTTPSuccess)

      json = JSON.parse(res.body)
      member = json.dig('response', 'GeoObjectCollection', 'featureMember', 0, 'GeoObject')
      return nil unless member

      pos = member.dig('Point', 'pos').to_s.split
      return nil if pos.size != 2

      lon, lat = pos.map(&:to_f)
      meta = member.dig('metaDataProperty', 'GeocoderMetaData') || {}
      ad = meta.dig('AddressDetails', 'Country', 'AdministrativeArea') || {}
      locality = ad.dig('Locality') || ad.dig('SubAdministrativeArea', 'Locality') || {}

      Result.new(
        latitude: lat, longitude: lon,
        formatted_address: meta['text'],
        city: locality['LocalityName'],
        district: locality.dig('DependentLocality', 'DependentLocalityName'),
        provider: 'yandex'
      )
    rescue StandardError => e
      Rails.logger.warn("[Geocoding] Yandex failed for #{@address.inspect}: #{e.class} #{e.message}")
      nil
    end

    def perform(uri, req)
      Net::HTTP.start(uri.host, uri.port,
                      use_ssl: uri.scheme == 'https',
                      open_timeout: 3, read_timeout: 5) { |h| h.request(req) }
    end
  end
end
