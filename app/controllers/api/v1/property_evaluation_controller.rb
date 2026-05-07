# frozen_string_literal: true

class Api::V1::PropertyEvaluationController < Api::V1::BaseController
  skip_before_action :authenticate_api_user!

  def create
    valuation = PropertyValuation.new(evaluation_params)
    result = PropertyEvaluationService.new(valuation).call

    if result[:success]
      render_success(result[:data])
    else
      render_error(result[:error] || 'Не удалось выполнить оценку', status: :unprocessable_entity)
    end
  end

  private

  def evaluation_params
    params.require(:evaluation).permit(
      :property_type, :deal_type, :address, :district, :metro_station,
      :total_area, :rooms, :floor, :total_floors, :building_year, :condition,
      :has_balcony, :has_loggia, :has_garage
    )
  end
end
