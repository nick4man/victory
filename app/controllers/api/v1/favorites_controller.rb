# frozen_string_literal: true

module Api
  module V1
    class FavoritesController < BaseController
      def index
        favorites = paginate(current_api_user.favorites.includes(:property))
        render_success(
          favorites.map { |f| { id: f.id, property_id: f.property_id, created_at: f.created_at } },
          meta: pagination_meta(favorites)
        )
      end

      def create
        property = Property.find(params[:property_id])
        favorite = current_api_user.favorite(property)
        render_created({ id: favorite.id, property_id: favorite.property_id })
      end

      def destroy
        current_api_user.favorites.where(property_id: params[:id]).destroy_all
        render_deleted
      end
    end
  end
end
