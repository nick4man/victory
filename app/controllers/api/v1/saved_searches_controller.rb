# frozen_string_literal: true

module Api
  module V1
    class SavedSearchesController < BaseController
      def index
        searches = paginate(current_api_user.saved_searches.order(created_at: :desc))
        render_success(searches.map { |s| serialize(s) }, meta: pagination_meta(searches))
      end

      def create
        search = current_api_user.saved_searches.new(search_params)
        if search.save
          render_created(serialize(search))
        else
          render_error('Validation failed', errors: search.errors.full_messages)
        end
      end

      def update
        search = current_api_user.saved_searches.find(params[:id])
        if search.update(search_params)
          render_updated(serialize(search))
        else
          render_error('Validation failed', errors: search.errors.full_messages)
        end
      end

      def destroy
        current_api_user.saved_searches.find(params[:id]).destroy
        render_deleted
      end

      private

      def search_params
        params.require(:saved_search).permit(:name, :query, filters: {})
      end

      def serialize(s)
        { id: s.id, name: s.name, query: s.query, filters: s.filters, created_at: s.created_at }
      end
    end
  end
end
