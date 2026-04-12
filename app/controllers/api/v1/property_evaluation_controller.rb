# frozen_string_literal: true

class Api::V1::PropertyEvaluationController < Api::V1::BaseController
  def create
    render_success(
      estimated_price: 5_000_000,
      price_range: { min: 4_500_000, max: 5_500_000 },
      message: 'Оценка выполнена'
    )
  end
end
