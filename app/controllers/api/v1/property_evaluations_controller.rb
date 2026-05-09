# frozen_string_literal: true

module Api
  module V1
    class PropertyEvaluationsController < BaseController
      skip_before_action :authenticate_api_user!, only: [:create]

      def create
        # Простейшая оценка по площади — стоимость кв.м из параметров.
        area = params[:area].to_f
        price_per_sqm = params[:price_per_sqm].to_f
        return render_bad_request('area/price_per_sqm required') if area <= 0 || price_per_sqm <= 0

        estimate = (area * price_per_sqm).round(0)
        render_success({
          estimate: estimate,
          range_min: (estimate * 0.92).round(0),
          range_max: (estimate * 1.08).round(0)
        })
      end
    end
  end
end
