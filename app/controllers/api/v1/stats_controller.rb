# frozen_string_literal: true

class Api::V1::StatsController < Api::V1::BaseController
  def index
    render_success(
      total_properties: Property.published.count,
      for_sale: Property.published.for_sale.count,
      for_rent: Property.published.for_rent.count
    )
  end
end
