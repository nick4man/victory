# frozen_string_literal: true

module Dashboard
  class ComparisonsController < BaseController
    def index
      render_coming_soon('Сравнение объектов')
    end

    def destroy
      head :ok
    end

    def clear_all
      redirect_to dashboard_comparisons_path, notice: 'Очищено.'
    end
  end
end
