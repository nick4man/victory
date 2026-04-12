# frozen_string_literal: true

module Api
  module V1
    class FavoritesController < BaseController
      # GET /api/v1/favorites
      def index
        @favorites = current_api_user.favorites
                                     .includes(property: :property_type)
                                     .recent

        @favorites = paginate(@favorites)

        render_success(
          favorites: serialize_favorites(@favorites),
          meta: pagination_meta(@favorites).merge(api_response_meta)
        )
      end

      # POST /api/v1/favorites
      def create
        property = Property.published.find(params[:property_id])

        favorite = current_api_user.favorites.find_or_initialize_by(property: property)

        if favorite.persisted?
          render_error('Объект уже добавлен в избранное', status: :unprocessable_entity)
        elsif favorite.save
          render_created(
            serialize_favorite(favorite),
            message: 'Объект добавлен в избранное'
          )
        else
          render_error(
            'Не удалось добавить в избранное',
            errors: favorite.errors.full_messages
          )
        end
      end

      # DELETE /api/v1/favorites/:id
      def destroy
        favorite = current_api_user.favorites.find(params[:id])
        favorite.destroy!

        render_deleted(message: 'Объект удалён из избранного')
      rescue ActiveRecord::RecordNotFound
        render_not_found('Запись не найдена в избранном')
      end

      # DELETE /api/v1/favorites/by_property/:property_id
      def destroy_by_property
        favorite = current_api_user.favorites.find_by!(property_id: params[:property_id])
        favorite.destroy!

        render_deleted(message: 'Объект удалён из избранного')
      rescue ActiveRecord::RecordNotFound
        render_not_found('Объект не найден в вашем избранном')
      end

      private

      def serialize_favorites(favorites)
        favorites.map { |f| serialize_favorite(f) }
      end

      def serialize_favorite(favorite)
        {
          id: favorite.id,
          created_at: favorite.created_at,
          property: favorite.property ? {
            id: favorite.property.id,
            title: favorite.property.title,
            slug: favorite.property.slug,
            price: favorite.property.price,
            price_formatted: favorite.property.price_formatted,
            deal_type: favorite.property.deal_type,
            area: favorite.property.area,
            rooms: favorite.property.rooms,
            district: favorite.property.district,
            metro_station: favorite.property.metro_station,
            property_type: favorite.property.property_type&.name,
            status: favorite.property.status
          } : nil
        }
      end
    end
  end
end
