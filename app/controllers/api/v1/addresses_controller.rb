# frozen_string_literal: true

module Api
  module V1
    # Address autocomplete endpoint backing the inline JS suggestion
    # dropdown on /valuations forms. Proxies DaData but caches in Redis,
    # rate-limits per IP, and never exposes the API token to the browser.
    class AddressesController < ApplicationController
      protect_from_forgery with: :null_session
      RATE_LIMIT = { count: 60, window: 1.minute }.freeze

      def autocomplete
        if rate_limited?
          render json: { error: 'rate_limited' }, status: :too_many_requests and return
        end

        suggestions = Dadata::AddressSuggestions.call(
          query: params[:q].to_s,
          limit: 8
        )

        render json: {
          query: params[:q].to_s,
          suggestions: suggestions.map { |s|
            { value: s.value, city: s.city, region: s.region, fias_id: s.fias_id }
          }
        }
      end

      private

      def rate_limited?
        return false unless defined?(Redis)
        key = "addr_autocomplete:#{request.remote_ip}"
        redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://redis:6379/1'))
        count = redis.incr(key)
        redis.expire(key, RATE_LIMIT[:window].to_i) if count == 1
        count > RATE_LIMIT[:count]
      rescue Redis::BaseError
        false
      end
    end
  end
end
