# frozen_string_literal: true

module Api
  module V1
    class RecommendationsController < BaseController
      def index
        properties = current_api_user.recommended_properties(20)
        render_success(properties.map { |p| serialize(p) })
      end

      private

      def serialize(p)
        {
          id: p.id,
          slug: p.slug,
          title: p.title,
          price: p.price,
          price_formatted: p.price_formatted,
          address: p.address,
          rooms: p.respond_to?(:rooms) ? p.rooms : nil
        }
      end
    end
  end
end
