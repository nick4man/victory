# frozen_string_literal: true

module Api
  module V1
    class StatsController < BaseController
      skip_before_action :authenticate_api_user!, only: [:index]

      def index
        render_success({
          properties: Property.published.count,
          for_sale: Property.published.where(deal_type: :sale).count,
          for_rent: Property.published.where(deal_type: :rent).count
        })
      end
    end
  end
end
