# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

# DaData /suggestions/api/4_1/rs/suggest/address proxy. Server-side because
# the public DADATA_API_KEY is OK to expose, but rate-limit + caching is
# cheaper to enforce here than per-browser. Cached in Rails.cache for 7 days
# per normalised query — repeat lookups hit Redis, not DaData (free tier
# 10k/day is plenty unless we leak the key into the wild).
#
# Defaults to Рязанская область (агентство в Рязани), but the locations
# filter is loose (city/region) so addresses from neighbouring regions still
# resolve when typed in full.
module Dadata
  class AddressSuggestions
    ENDPOINT = 'https://suggestions.dadata.ru/suggestions/api/4_1/rs/suggest/address'
    CACHE_TTL = 7.days
    MIN_QUERY = 2
    MAX_LIMIT = 10

    # Country-wide suggestions — empty array tells DaData not to bias the
    # result. Previously we biased toward Рязанская обл., but the agency
    # now serves clients across Russia (Topnlab catalog contains rows from
    # Moscow, SPb, Krasnodar, etc.).
    LOCATIONS = [].freeze

    Suggestion = Struct.new(:value, :unrestricted_value, :city, :region,
                            :street, :house, :fias_id, :latitude, :longitude,
                            keyword_init: true)

    def self.call(query:, limit: MAX_LIMIT)
      return [] if query.to_s.strip.length < MIN_QUERY
      new(query, limit).call
    end

    def initialize(query, limit)
      @query = query.to_s.strip
      @limit = [limit.to_i, 1].max.clamp(1, MAX_LIMIT)
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { fetch }
    end

    private

    def cache_key
      "dadata:addr:#{Digest::SHA1.hexdigest(@query.downcase)}:#{@limit}"
    end

    def fetch
      token = ENV['DADATA_API_KEY'].to_s
      return [] if token.empty?

      uri = URI(ENDPOINT)
      req = Net::HTTP::Post.new(uri,
                                'Content-Type'  => 'application/json',
                                'Accept'        => 'application/json',
                                'Authorization' => "Token #{token}")
      req.body = JSON.generate(
        query: @query,
        count: @limit,
        locations: LOCATIONS,
        from_bound: { value: 'street' },  # avoid city-only matches when user types a street
        to_bound:   { value: 'house' }
      )

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                            open_timeout: 3, read_timeout: 5) { |h| h.request(req) }
      return [] unless res.is_a?(Net::HTTPSuccess)

      data = JSON.parse(res.body) rescue {}
      Array(data['suggestions']).map { |s| build_suggestion(s) }
    rescue StandardError => e
      Rails.logger.warn("[Dadata::AddressSuggestions] #{e.class}: #{e.message}")
      []
    end

    def build_suggestion(s)
      d = s['data'] || {}
      Suggestion.new(
        value:               s['value'],
        unrestricted_value:  s['unrestricted_value'],
        city:                d['city'] || d['settlement'],
        region:              d['region_with_type'] || d['region'],
        street:              d['street_with_type'] || d['street'],
        house:               [d['house_type'], d['house']].compact.join(' ').presence,
        fias_id:             d['fias_id'],
        latitude:            d['geo_lat']&.to_f,
        longitude:           d['geo_lon']&.to_f
      )
    end
  end
end
