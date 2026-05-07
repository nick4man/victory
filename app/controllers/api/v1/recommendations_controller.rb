# frozen_string_literal: true

module Api
  module V1
    class RecommendationsController < BaseController
      skip_before_action :authenticate_api_user!, only: [:popular]

      # GET /api/v1/recommendations
      # Personalized recommendations for the authenticated user
      def index
        service = RecommendationService.new(current_api_user)
        recommendations = service.call

        render_success(
          recommendations: serialize_properties(recommendations),
          meta: {
            count: recommendations.size,
            based_on: recommendation_basis
          }.merge(api_response_meta)
        )
      end

      # GET /api/v1/recommendations/popular
      # Most viewed/favorited properties (public endpoint)
      def popular
        limit = params[:limit].blank? ? 10 : [[params[:limit].to_i, 1].max, 50].min

        @properties = Property.published
                              .order(views_count: :desc, favorites_count: :desc)
                              .includes(:property_type)
                              .limit(limit)

        render_success(
          recommendations: serialize_properties(@properties),
          meta: { count: @properties.size }.merge(api_response_meta)
        )
      end

      private

      def recommendation_basis
        if current_api_user.favorites.any?
          'favorites'
        elsif current_api_user.property_views.any?
          'view_history'
        else
          'popular'
        end
      end

      def serialize_properties(properties)
        properties.map do |property|
          {
            id: property.id,
            title: property.title,
            slug: property.slug,
            price: property.price,
            price_formatted: property.price_formatted,
            deal_type: property.deal_type,
            area: property.area,
            rooms: property.rooms,
            district: property.district,
            metro_station: property.metro_station,
            property_type: property.property_type&.name,
            views_count: property.views_count,
            favorites_count: property.favorites_count,
            is_featured: property.is_featured,
            published_at: property.published_at
          }
        end
      end
    end
  end
end
